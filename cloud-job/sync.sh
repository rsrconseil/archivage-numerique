#!/bin/sh
# =====================================================================
#  Miroir SharePoint / OneDrive -> Scaleway Object Storage      (v3.2, 24/09/2026)
#  Exécuté par Scaleway Serverless Jobs, image alpine, sans machine locale.
#
#  Découverte automatique : à chaque exécution, le script demande à Microsoft
#  Graph la liste de TOUS les sites SharePoint du tenant, descend dans leurs
#  sous-sites (3 niveaux), liste leurs bibliothèques et les copie une par une.
#  Un site créé dans la semaine est sauvegardé au passage suivant.
#  On choisit ce qu'on exclut, pas ce qu'on inclut.
#
#  Rien n'est jamais supprimé du bucket : ce que rclone effacerait ou écraserait
#  est déplacé dans _corbeille/<date>/ (purgé à 90 jours par la règle de cycle de
#  vie du bucket). Un inventaire de l'exécution est déposé dans _inventaire/.
#
#  Garde-fous :
#    - jeton Graph renouvelé avant chaque appel s'il a plus de 40 minutes (il expire à 1 h) ;
#    - limitation de débit Graph (429/503) : attente du délai demandé par Microsoft, 12 essais ;
#    - toute autre erreur Graph est comptée comme ECHEC et inscrite dans l'inventaire ;
#    - noms de dossier uniques dans le bucket : site racine = "Site racine", homonymes suffixés
#      par le nom du site dans l'URL, sous-sites rangés sous leur parent ("Site racine/Projets Passés") ;
#    - MUST_SITES : sites qui doivent être en OK, sinon l'exécution est en échec.
#
#  Variables d'environnement
#    Obligatoires : TENANT_ID, CLIENT_ID, CLIENT_SECRET (secret),
#                   SCW_ACCESS_KEY, SCW_SECRET_KEY (secret), BUCKET
#    Optionnelles : MUST_SITES     dossiers de sites obligatoires, séparés par ';'
#                   EXCLUDE_SITES  sites à ignorer (nom d'affichage ou dossier), séparés par ';'
#                   EXCLUDE_LIBS   bibliothèques à ignorer (défaut : techniques SharePoint)
#                   ONLY_SITES     pour un test : ne traiter que ces sites (';')
#                   ONEDRIVE_USER  mode perso : ne copier que le OneDrive de cet utilisateur
#                   DRY_RUN=1      simulation rclone, rien n'est écrit dans le bucket
#
#  Code de sortie : 0 si tout a réussi, 1 si au moins un échec ou un site obligatoire
#  manquant, 2 si l'environnement est inutilisable (outils, jeton).
# =====================================================================
set -u
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${SCW_ACCESS_KEY:?}" "${SCW_SECRET_KEY:?}" "${BUCKET:?}"
MUST_SITES="${MUST_SITES:-}"
EXCLUDE_SITES="${EXCLUDE_SITES:-}"
EXCLUDE_LIBS="${EXCLUDE_LIBS:-Site Assets;Form Templates;Style Library;Teams Wiki Data;Preservation Hold Library;Site Pages;Site Collection Documents;Site Collection Images;Translation Packages;Images;Pages;Éléments de site;Modèles de formulaire;Bibliothèque de styles;Données Wiki Teams;Bibliothèque de conservation;Pages du site;Documents de la collection de sites;Images de la collection de sites;Packages de traduction}"
ONLY_SITES="${ONLY_SITES:-}"
ONEDRIVE_USER="${ONEDRIVE_USER:-}"
DRY_RUN="${DRY_RUN:-0}"

DATE=$(date +%Y%m%d-%H%M)
INV=/tmp/inventaire.txt
SITES=/tmp/sites.tsv          # id, nom, url  (premier niveau, depuis getAllSites)
ALL=/tmp/tous.tsv             # id, dossier, nom  (premier niveau + sous-sites)
DRIVES=/tmp/drives.tsv
GRAPH_ERR=/tmp/graph_error.txt
: > "$INV"
OK=0; KO=0; SKIP=0

echo "=== Miroir RSR -> $BUCKET, $DATE $( [ "$DRY_RUN" = 1 ] && echo '(SIMULATION)' ) ==="

# ---------- outils ----------
if ! command -v rclone >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    apk add --no-cache -q rclone curl jq ca-certificates || { echo "ERREUR : installation des outils impossible"; exit 2; }
fi
rclone version | head -1

# ---------- rclone par variables d'environnement, aucun fichier ----------
export RCLONE_CONFIG_SCW_TYPE=s3
export RCLONE_CONFIG_SCW_PROVIDER=Scaleway
export RCLONE_CONFIG_SCW_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export RCLONE_CONFIG_SCW_REGION=fr-par
export RCLONE_CONFIG_SCW_ENDPOINT=s3.fr-par.scw.cloud
export RCLONE_CONFIG_SCW_ACL=private
export RCLONE_CONFIG_SCW_STORAGE_CLASS=STANDARD
export RCLONE_CONFIG_SCW_NO_CHECK_BUCKET=true   # la clé n'a pas le droit de créer un bucket : ne pas essayer

export RCLONE_CONFIG_SP_TYPE=onedrive
export RCLONE_CONFIG_SP_CLIENT_ID="$CLIENT_ID"
export RCLONE_CONFIG_SP_CLIENT_SECRET="$CLIENT_SECRET"
export RCLONE_CONFIG_SP_TENANT="$TENANT_ID"
export RCLONE_CONFIG_SP_CLIENT_CREDENTIALS=true

# ---------- jeton Microsoft Graph, renouvelé quand il a plus de 40 minutes ----------
TOKEN=""; TOKEN_T=0
get_token() {
    now=$(date +%s)
    [ -n "$TOKEN" ] && [ $((now - TOKEN_T)) -lt 2400 ] && return 0
    TOKEN=$(curl -sS --retry 5 --retry-delay 5 -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
        -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
        -d scope="https://graph.microsoft.com/.default" -d grant_type=client_credentials | jq -r '.access_token // empty')
    [ -n "$TOKEN" ] || { echo "ERREUR : jeton Graph non obtenu (identifiants ou consentement)"; return 1; }
    TOKEN_T=$now
}
get_token || exit 2

graph() {   # une requête Graph avec reprise : limitation de débit (429/503) -> attente du délai demandé, jusqu'à 12 essais ;
            # jeton refusé (401) -> renouvellement ; autre erreur -> message dans $GRAPH_ERR et retour 1
    n=0
    while :; do
        n=$((n+1))
        get_token || return 1
        rep=$(curl -sS -D /tmp/entetes.txt -H "Authorization: Bearer $TOKEN" "$1"); rc=$?
        code=$(head -1 /tmp/entetes.txt 2>/dev/null | awk '{print $2}')
        if [ $rc -eq 0 ] && [ "$code" = 200 ]; then printf '%s' "$rep"; return 0; fi
        if [ $n -ge 12 ]; then
            echo "Graph : abandon après $n essais (dernier code ${code:-réseau}) sur $1" > "$GRAPH_ERR"; return 1
        fi
        case "$code" in
            429|503|504|'')
                wait=$(grep -i '^Retry-After:' /tmp/entetes.txt 2>/dev/null | tr -d '\r' | awk '{print $2}')
                [ -n "$wait" ] && [ "$wait" -eq "$wait" ] 2>/dev/null || wait=60
                [ "$wait" -gt 600 ] && wait=600
                echo "Graph : code ${code:-réseau} (limitation de débit), nouvel essai dans ${wait}s ($n/12)" >&2
                sleep "$wait"; continue ;;
            401)
                echo "Graph : jeton refusé, renouvellement ($n/12)" >&2; TOKEN=""; sleep 5; continue ;;
            *)
                err=$(printf '%s' "$rep" | jq -r '.error.message // empty' 2>/dev/null)
                echo "HTTP $code : ${err:-$rep}" > "$GRAPH_ERR"; return 1 ;;
        esac
    done
}
graph_all() {   # suit la pagination, émet une ligne TSV par élément selon le filtre jq $2 ; renvoie 1 si une page a échoué
    url=$1; rc=0
    while [ -n "$url" ]; do
        page=$(graph "$url") || { rc=1; break; }
        printf '%s' "$page" | jq -r "$2"
        url=$(printf '%s' "$page" | jq -r '."@odata.nextLink" // empty')
    done
    return $rc
}
in_list()   { case ";$2;" in *";$1;"*) return 0 ;; esac; return 1; }   # $1 valeur, $2 liste ';'
lib_exclue() {   # bibliothèques techniques : liste EXCLUDE_LIBS, ou motifs générés par SharePoint
    in_list "$1" "$EXCLUDE_LIBS" && return 0
    case "$1" in PersistedManagedNavigationList*|"Site Collection "*|*" de la collection de sites") return 0 ;; esac
    return 1
}
safe()    { printf '%s' "$1" | tr '/\\:*?"<>|' '_________' | sed 's/[. ]*$//'; }
note()    { printf '%s\n' "$1" | tee -a "$INV"; }

# ---------- copie d'un lecteur ----------
mirror() {   # $1 drive_id, $2 drive_type, $3 dossier dans le bucket, $4 libellé
    t0=$(date +%s)
    echo "--- $4  ->  $BUCKET/$3"
    extra=""; [ "$DRY_RUN" = 1 ] && extra="--dry-run"
    if rclone sync "sp:" "scw:$BUCKET/$3" \
        --onedrive-drive-id "$1" --onedrive-drive-type "$2" \
        --backup-dir "scw:$BUCKET/_corbeille/$DATE/$3" \
        --exclude '~$*' --exclude '*.tmp' --exclude 'desktop.ini' \
        --onedrive-delta --fast-list \
        --transfers 8 --checkers 16 --retries 3 --low-level-retries 10 \
        --stats 5m --stats-one-line -v $extra; then
        OK=$((OK+1)); st=OK
    else
        KO=$((KO+1)); st="ECHEC"
    fi
    note "$(printf '%s\t%s\t%s\t%s\t%ss' "$st" "$4" "$3" "$1" "$(( $(date +%s) - t0 ))")"
}

# ---------- mode perso : un seul OneDrive ----------
if [ -n "$ONEDRIVE_USER" ]; then
    did=$(graph "https://graph.microsoft.com/v1.0/users/$ONEDRIVE_USER/drive?\$select=id" | jq -r '.id // empty')
    [ -n "$did" ] || { echo "ERREUR : OneDrive de $ONEDRIVE_USER introuvable : $(cat "$GRAPH_ERR" 2>/dev/null)"; exit 2; }
    mirror "$did" business "OneDrive - $(safe "$ONEDRIVE_USER")" "OneDrive $ONEDRIVE_USER"
else
# ---------- mode cabinet : découverte des sites de premier niveau ----------
    if ! graph_all "https://graph.microsoft.com/v1.0/sites/getAllSites?\$select=id,displayName,webUrl" \
        '.value[] | [.id, (.displayName // .name // "sans-nom"), .webUrl] | @tsv' > "$SITES"; then
        echo "ERREUR : liste des sites incomplète : $(cat "$GRAPH_ERR" 2>/dev/null)"; exit 2
    fi
    grep -v -- '-my.sharepoint.com/' "$SITES" > "$SITES.f" && mv "$SITES.f" "$SITES"   # OneDrive personnels : hors périmètre ici
    cut -f2 "$SITES" | sort | uniq -d > /tmp/homonymes.txt

    # nom de dossier unique par site de premier niveau
    : > "$ALL"
    while IFS="$(printf '\t')" read -r sid sname surl; do
        chemin=$(printf '%s' "$surl" | sed -E 's#^https?://[^/]+##; s#/$##')
        if [ -z "$chemin" ]; then dossier="Site racine"
        elif grep -qxF -- "$sname" /tmp/homonymes.txt; then dossier="$(safe "$sname") ($(safe "${chemin##*/}"))"
        else dossier="$(safe "$sname")"; fi
        printf '%s\t%s\t%s\n' "$sid" "$dossier" "$sname" >> "$ALL"
    done < "$SITES"
    echo "Sites de premier niveau : $(wc -l < "$ALL")"

    # ---------- sous-sites, 3 niveaux (getAllSites ne les renvoie pas) ----------
    cp "$ALL" /tmp/niveau.tsv
    for prof in 1 2 3; do
        : > /tmp/suivant.tsv
        while IFS="$(printf '\t')" read -r sid dossier sname; do
            if in_list "$sname" "$EXCLUDE_SITES" || in_list "$dossier" "$EXCLUDE_SITES"; then continue; fi
            if ! graph_all "https://graph.microsoft.com/v1.0/sites/$sid/sites?\$select=id,displayName,webUrl" \
                '.value[] | [.id, (.displayName // .name // "sans-nom")] | @tsv' > /tmp/enfants.tsv; then
                KO=$((KO+1)); note "$(printf 'ECHEC\t%s\t(liste des sous-sites : %s)' "$dossier" "$(cat "$GRAPH_ERR" 2>/dev/null)")"; continue
            fi
            while IFS="$(printf '\t')" read -r cid cname; do
                [ -n "$cid" ] || continue
                printf '%s\t%s/%s\t%s\n' "$cid" "$dossier" "$(safe "$cname")" "$cname" >> /tmp/suivant.tsv
            done < /tmp/enfants.tsv
        done < /tmp/niveau.tsv
        [ -s /tmp/suivant.tsv ] || break
        echo "Sous-sites de niveau $prof : $(wc -l < /tmp/suivant.tsv)"
        cat /tmp/suivant.tsv >> "$ALL"; cp /tmp/suivant.tsv /tmp/niveau.tsv
    done
    echo "Sites et sous-sites à traiter : $(wc -l < "$ALL")"

    # ---------- copie ----------
    while IFS="$(printf '\t')" read -r sid dossier sname; do
        if in_list "$sname" "$EXCLUDE_SITES" || in_list "$dossier" "$EXCLUDE_SITES"; then SKIP=$((SKIP+1)); note "$(printf 'EXCLU\t%s' "$dossier")"; continue; fi
        if [ -n "$ONLY_SITES" ] && ! in_list "$sname" "$ONLY_SITES" && ! in_list "$dossier" "$ONLY_SITES"; then continue; fi

        if ! graph_all "https://graph.microsoft.com/v1.0/sites/$sid/drives?\$select=id,name,driveType" \
            '.value[] | select(.driveType=="documentLibrary") | [.id, .name] | @tsv' > "$DRIVES"; then
            KO=$((KO+1)); note "$(printf 'ECHEC\t%s\t(liste des bibliothèques : %s)' "$dossier" "$(cat "$GRAPH_ERR" 2>/dev/null)")"; continue
        fi
        n=0
        while IFS="$(printf '\t')" read -r did dname; do
            [ -n "$did" ] || continue
            lib_exclue "$dname" && continue
            n=$((n+1))
            mirror "$did" documentLibrary "$dossier/$(safe "$dname")" "$dossier / $dname"
        done < "$DRIVES"
        [ "$n" -eq 0 ] && note "$(printf 'VIDE\t%s\t(aucune bibliothèque de documents)' "$dossier")"
    done < "$ALL"

    # ---------- sites obligatoires ----------
    OLDIFS=$IFS; IFS=';'
    for m in $MUST_SITES; do
        IFS=$OLDIFS
        [ -n "$m" ] || continue
        if ! grep -q "^OK	$m / " "$INV"; then KO=$((KO+1)); note "$(printf 'MANQUANT\t%s\t(site obligatoire absent ou en échec)' "$m")"; fi
        IFS=';'
    done
    IFS=$OLDIFS
fi

# ---------- inventaire et bilan ----------
echo "=== Bilan $DATE : $OK OK, $KO échec(s), $SKIP site(s) exclu(s) ==="
if [ "$DRY_RUN" != 1 ]; then
    { printf 'date\t%s\nbucket\t%s\nok\t%s\nechecs\t%s\n' "$DATE" "$BUCKET" "$OK" "$KO"; cat "$INV"; } \
        | rclone rcat "scw:$BUCKET/_inventaire/$DATE.tsv" || echo "AVERTISSEMENT : inventaire non déposé"
fi
[ "$KO" -eq 0 ]
