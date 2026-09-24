# nas-pull : copie des buckets Scaleway vers le NAS UniFi

Rôle : la copie de secours locale, voie A. Le PC de Raphaël recopie chaque semaine les trois buckets vers les trois partages du NAS, quand il est sur le réseau du cabinet ou en VPN. Le cloud reste la référence ; le NAS est là si le cloud fait défaut.

| Bucket | Partage NAS |
|---|---|
| rsr-miroir | \\\\192.168.9.139\\Synchro_OneDrive |
| rsr-archives | \\\\192.168.9.139\\Sauvegarde_Projets_historiques |
| rsr-perso | \\\\192.168.9.139\\Personal-Drive |

La corbeille du bucket (`_corbeille/`) n'est pas recopiée. Sur le NAS, ce que la copie supprime ou écrase va dans `z-corbeille\<date>` du partage, purgé après 90 jours, en plus des instantanés du NAS.

## Installation (une fois, 15 min)

1. **Clé Scaleway en lecture seule.** IAM > Applications > créer `pc-raphael-lecture`, politique limitée au projet `rsr-archivage` avec `ObjectStorageObjectsRead` et `ObjectStorageBucketsRead` uniquement. Générer une clé API. Cette clé ne peut ni écrire ni supprimer dans les buckets : si le PC est compromis, le cloud reste intact.
2. **Remote rclone `scw-lecture` sur le PC** (la commande demande les deux clés, elles sont stockées dans `%APPDATA%\rclone\rclone.conf`) :

```powershell
rclone config create scw-lecture s3 provider=Scaleway region=fr-par endpoint=s3.fr-par.scw.cloud acl=private no_check_bucket=true access_key_id=<ACCESS_KEY> secret_access_key=<SECRET_KEY>
```

3. **Contrôle** :

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\RaphaeldeSaintRomain\OneDrive - Raphaël de Saint Romain Conseil et Investissement\Q- RSR C&I\R- Code\2511-Archivage Numérique\nas-pull\NasPull.ps1" -Action Check
```

   Attendu : rclone présent, remote présent, NAS joignable, trois partages accessibles, taille des trois buckets.

4. **Simulation puis première copie** (la première copie du miroir prend plusieurs heures, elle rapatrie tout depuis le cloud) :

```powershell
powershell -ExecutionPolicy Bypass -File "...\nas-pull\NasPull.ps1" -Action Sync -DryRun -Force
powershell -ExecutionPolicy Bypass -File "...\nas-pull\NasPull.ps1" -Action Sync -Force
```

5. **Tâche planifiée** :

```powershell
powershell -ExecutionPolicy Bypass -File "...\nas-pull\Installer-Tache.ps1"
```

   Elle se déclenche chaque jour à 10 h et à chaque ouverture de session. Le script décide seul : rien à faire si la dernière réussite a moins de 7 jours ou si le NAS ne répond pas, sinon copie.

## Longue copie et mise en veille

La première copie dure des heures ; le PC se met en veille après 3 h sans activité sur secteur. Pour une copie longue, lancer en parallèle `Garder-Eveille.ps1` : il retient la veille tant que le verrou de nas-pull existe, comme le ferait un lecteur vidéo, sans modifier les réglages, et se termine seul. Il ne protège pas d'un couvercle fermé ni d'une veille demandée à la main. Les copies hebdomadaires suivantes durent quelques minutes et n'en ont pas besoin.

## Contrôle mensuel (2 min)

```powershell
powershell -ExecutionPolicy Bypass -File "...\nas-pull\NasPull.ps1" -Action Check
```

La section « Dernières copies » doit montrer les trois cibles à moins de 14 jours. Un « en retard » signifie que le PC n'a pas vu le NAS depuis deux semaines : se connecter au réseau du cabinet ou au VPN et lancer `-Action Sync -Force`.

## Points connus

- **Noms de fichiers.** Windows refuse certains caractères (`:`, `?`, `*`) et les noms terminés par un point ou un espace ; rclone les transcrit automatiquement en équivalents visuels. Les chemins très longs peuvent en revanche échouer côté NAS : ils apparaissent alors en `ECHEC` dans le journal avec le fichier en cause dans le log. La solution est de renommer le fichier dans SharePoint.
- **Le partage Synchro_OneDrive contient encore le miroir de décembre 2025** fait directement depuis SharePoint. La première copie depuis le bucket le réorganisera par site et bibliothèque ; les anciens dossiers de premier niveau iront dans `z-corbeille`. C'est volumineux mais sans risque, et purgé à 90 jours.
- **Le NAS n'est pas joignable hors du cabinet** sans VPN. Voir avec la Dream Machine (Teleport ou WireGuard) si des absences longues sont fréquentes.

## Amorçage : ce qui est déjà sur le NAS (une fois, avant la première copie)

Le partage Sauvegarde_Projets_historiques contient les archives 2013-2019 du cabinet, dont une partie n'existe nulle part ailleurs. Le bucket `rsr-archives` est vide. On inverse donc le flux une fois : le NAS amorce le bucket, puis nas-pull entretient. Le script `Amorcer-Archives.ps1` le fait en cinq étapes, chacune rejouable et simulable avec `-WhatIf`.

| Étape | Ce qu'elle fait | Modifie quoi |
|---|---|---|
| `Doublons` | compare les dossiers du staging qui existent encore sur SharePoint (projets 2020, Carso) avec la copie locale synchronisée | rien (un rapport dans les logs) |
| `Reorganiser` | déplace les projets dans `Conseil\` et `M&A\` sur le NAS, doublons laissés en place | le NAS, par renommage |
| `Envoyer` | copie `Conseil\`, `M&A\` vers `rsr-archives`, et `Photos\` + les deux `.pst` vers `rsr-perso` | le cloud, ajout seulement |
| `Verifier` | contrôle que chaque fichier du NAS est dans le bucket, même taille et empreinte | rien |
| `Nettoyer` | supprime les doublons identiques à SharePoint, les 42 zips et les dossiers de staging vidés | le NAS ; refusé tant que Verifier n'a pas réussi |

Les projets 2020 ne sont pas envoyés depuis le NAS : SharePoint en détient la version de référence, plus récente. Ils seront archivés par le rituel annuel, depuis le bucket miroir. Un doublon dont le contenu diffère de SharePoint n'est jamais supprimé par le script : il est signalé pour arbitrage.

L'étape `Envoyer` a besoin d'un remote rclone **avec droit d'écriture**, temporaire. Dans IAM, sur l'application `job-archivage`, générer une seconde clé API, puis sur le PC :

```powershell
rclone config create scw-ecriture s3 provider=Scaleway region=fr-par endpoint=s3.fr-par.scw.cloud acl=private no_check_bucket=true access_key_id=<ACCESS_KEY> secret_access_key=<SECRET_KEY>
```

Une fois `Nettoyer` passé, supprimer cette clé dans IAM et le remote sur le PC :

```powershell
rclone config delete scw-ecriture
```

Volumes à envoyer (mesurés le 23/09/2026) : archives conseil et M&A environ 30 Go, archives Outlook 33 Go, photos à mesurer. Comptez une nuit sur le réseau du cabinet.
