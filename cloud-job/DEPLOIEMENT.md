# Déploiement du job cloud (miroir SharePoint vers Scaleway, découverte automatique)

Ordre à respecter : Microsoft d'abord (l'application), puis Scaleway.
Tout se fait dans les consoles web. Aucun fichier de configuration rclone : tout passe par des variables d'environnement, et le job découvre lui-même les sites à copier.

## A. Microsoft Entra ID : l'application « RSR Archivage » — FAIT le 23/09/2026

- ID de l'annuaire (tenant) : `7356cc20-2024-4882-8256-7fc44d0bfa16`
- ID d'application (client) : `33c5f192-9075-462e-a048-d7c4c7586591`
- Permissions d'application `Sites.Read.All` et `Files.Read.All`, consentement administrateur accordé (vérifié : le jeton porte les deux rôles).
- Secret client créé pour 24 mois. Rappel de renouvellement programmé au 23/07/2028.

Pour le job perso, deux choix : la même application (`Files.Read.All` couvre les OneDrive utilisateurs), ou une seconde inscription `RSR Archivage Perso` avec son propre secret, pour cloisonner.

## B. Vérification du périmètre vu par l'application (5 min, PC)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\RaphaeldeSaintRomain\OneDrive - Raphaël de Saint Romain Conseil et Investissement\Q- RSR C&I\R- Code\2511-Archivage Numérique\cloud-job\Get-DriveIds.ps1" -TenantId 7356cc20-2024-4882-8256-7fc44d0bfa16 -ClientId 33c5f192-9075-462e-a048-d7c4c7586591
```

Ce script ne sert plus à configurer le job (il découvre seul) : il sert à contrôler, au déploiement puis une fois par an, que l'application voit bien les bibliothèques connues et que leur contenu correspond. `bibliotheques.json` est l'état de référence au 23/09/2026.

## C. Scaleway (30 min)

1. **Projet** : créer un projet `rsr-archivage` (Organisation > Projets) pour isoler les droits.
2. **Buckets** (Object Storage, région fr-par, visibilité privée) : `rsr-miroir`, `rsr-archives`, `rsr-perso`.
   Sur chacun : activer le **versioning des objets**, puis ajouter une **règle de cycle de vie** :
   préfixe `_corbeille/`, expiration des objets à 90 jours ; et expiration des versions non courantes à 90 jours.
3. **Clé API** (IAM > Applications) : créer une application `job-archivage`, lui attacher une politique
   limitée au projet `rsr-archivage` avec `ObjectStorageObjectsRead`, `ObjectStorageObjectsWrite`,
   `ObjectStorageObjectsDelete` et `ObjectStorageBucketsRead`. Pas de droit sur les buckets eux-mêmes (création, suppression, règles).
   Générer une clé API : noter access key et secret key.
   Le droit de suppression est nécessaire : la corbeille datée est un déplacement, donc une copie suivie d'une suppression,
   et la synchro doit pouvoir retirer du préfixe courant ce qui a quitté SharePoint. La protection contre un usage
   malveillant de cette clé vient du versioning : une suppression ne pose qu'un marqueur, l'ancienne version reste
   90 jours (règle `versions-anciennes`) et se restaure depuis la console ou avec `rclone --s3-versions`.
   (Constaté le 23/09/2026 : sans ce droit, chaque suppression côté SharePoint met la bibliothèque en ECHEC avec AccessDenied.)
4. **Secrets** (Secret Manager, région fr-par), trois secrets :
   - `entra-client-secret` : la valeur du secret de l'application Entra (type opaque)
   - `scw-secret-key` : la secret key de la clé API ci-dessus (type opaque)
   - `sync-sh` : le contenu du fichier `cloud-job/sync.sh` (type opaque, collé tel quel)
   Le script n'est pas secret, mais Secret Manager est le seul moyen simple de fournir un fichier à un job.
5. **Job cabinet** (Serverless > Jobs > Créer une définition) :
   - Nom : `rsr-miroir`
   - Image : `alpine:3.22` (registre public). Le script installe rclone, curl et jq au lancement, une dizaine de secondes.
   - Ressources : 1 vCPU, 2 Go, délai maximal 8 h (le chargement initial est long, les suivants durent quelques minutes)
   - Commande : `sh /scripts/sync.sh`
   - Variables d'environnement :
     `TENANT_ID=7356cc20-2024-4882-8256-7fc44d0bfa16`
     `CLIENT_ID=33c5f192-9075-462e-a048-d7c4c7586591`
     `SCW_ACCESS_KEY=<access key de l'étape 3>`
     `BUCKET=rsr-miroir`
     `MUST_SITES=Site racine/Projets Passés;Projets conseil traditionnel;Projets M&A;Admin RSR Conseil;Vie du cabinet;Propositions commerciales;je-vends-ma-pme.com;Datarooms RSR Conseil;CODIR`
     (sites qui doivent être en OK à chaque exécution, sinon échec et alerte ; ajouter ici tout site jugé critique)
     `EXCLUDE_SITES=sans-nom;Project Web App;Outlook Customer Manager;Site d'équipe (contentTypeHub);All Company (allcompany);All Company (AllCompany.4828718.abqtpkoz)`
     (sites techniques sans documents métier, constatés dans l'inventaire du 23/09/2026 ; compléter au fil des inventaires)
   - Références de secrets :
     `entra-client-secret` → variable d'environnement `CLIENT_SECRET`
     `scw-secret-key` → variable d'environnement `SCW_SECRET_KEY`
     `sync-sh` → fichier `/scripts/sync.sh`
   - Planification : `0 3 * * 1` (lundi 3 h), fuseau `Europe/Paris`
6. **Job perso** : dupliquer la définition sous le nom `rsr-miroir-perso`, avec `BUCKET=rsr-perso`,
   `ONEDRIVE_USER=raphael@rsr-conseil.fr`, planification `0 4 * * 1`. Si une application Entra distincte a été créée,
   remplacer `CLIENT_ID` et le secret `CLIENT_SECRET` par les siens.
7. **Alerte** : Cockpit > Alertes, règle sur les exécutions de job en état `failed`, e-mail vers raphael@rsr-conseil.fr.

Rangement dans le bucket : un dossier par site, nommé d'après son nom d'affichage ; le site racine s'appelle `Site racine` ; ses sous-sites (Projets Passés, Projets 2012-2014, Projets 2015-2016, Projets en Cours, Dossier Partagé, test) sont rangés dessous, par exemple `Site racine/Projets Passés/Documents` ; deux sites homonymes (« All Company », « Site d'équipe ») reçoivent un suffixe tiré de leur URL.

## D. Premier lancement et validation (1 h)

1. **Simulation à périmètre réduit** : ajouter temporairement aux variables `DRY_RUN=1` et `ONLY_SITES=Admin RSR Conseil`, bouton « Run job », lire le journal. On doit voir « Sites trouvés : N », puis une seule bibliothèque traitée, sans transfert réel.
2. **Copie réelle réduite** : retirer `DRY_RUN`, relancer. Vérifier dans le bucket le dossier `Admin RSR Conseil/Documents/` et le fichier `_inventaire/<date>.tsv`. Relancer une seconde fois : rien ne doit être transféré.
3. **Corbeille** : supprimer un fichier de test dans SharePoint, relancer : il doit apparaître dans `_corbeille/<date>/Admin RSR Conseil/Documents/`.
4. **Périmètre complet** : retirer `ONLY_SITES`, lancer manuellement une fois (plusieurs heures), puis laisser la planification faire.
5. Lire l'inventaire : chaque site attendu doit y figurer en `OK`. Compléter `EXCLUDE_SITES` pour ce qui ne doit pas être copié.

Incident du 24/09/2026, corrigé en v3.2 : la liste globale de Graph ne renvoie pas les sous-sites ; Projets Passés et cinq autres sous-sites du site racine n'étaient pas copiés. Le script descend désormais trois niveaux de sous-sites.

Incident du 23/09/2026, corrigé en v3 du script : le jeton Graph expirait après une heure, les sites traités ensuite étaient silencieusement ignorés (dont Projets Passés, Projets conseil traditionnel, Vie du cabinet, je-vends-ma-pme.com). Le script renouvelle désormais le jeton avant chaque site, compte tout refus de Graph comme échec, et vérifie `MUST_SITES`.

## E. Contrôle mensuel (5 min)

- Serverless > Jobs > `rsr-miroir` > Exécutions : la dernière est `succeeded` et date de moins de 8 jours.
- Ouvrir le dernier `_inventaire/<date>.tsv` dans le bucket : aucune ligne `ECHEC`, et les nouveaux sites du mois y figurent.
- Object Storage : la taille du bucket évolue de façon plausible.

## F. Renouvellement

| Élément | Durée | Où renouveler |
|---|---|---|
| Secret de l'application Entra | 24 mois (créé 09/2026, rappel 23/07/2028) | Entra > l'application > Certificats et secrets, puis nouvelle version du secret `entra-client-secret` |
| Clé API Scaleway | sans expiration | IAM, en cas de doute sur sa confidentialité |
| Image alpine / version rclone | libre | changer le tag `3.22` dans la définition du job |
| Script `sync.sh` | à chaque modification | nouvelle version du secret `sync-sh`, puis un « Run job » de contrôle |
