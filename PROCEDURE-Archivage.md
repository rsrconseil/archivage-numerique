# Procédure d'exploitation de l'archivage numérique RSR Conseil

Version 3, 25 septembre 2026. Remplace la procédure de novembre 2025 (12 scripts .bat, conservés dans `legacy/`).
Le détail technique de chaque brique est dans son dossier : `cloud-job/DEPLOIEMENT.md`, `nas-pull/INSTALLATION.md`, `archivage-annuel/PROCEDURE.md`.

## 1. Ce qui tourne, et où

| Brique | Où | Quand | Qui déclenche |
|---|---|---|---|
| Miroir cloud des bibliothèques SharePoint | Scaleway Serverless Jobs, job `rsr-miroir`, bucket `rsr-miroir` | lundi 3 h | Scaleway, seul |
| Miroir cloud du OneDrive de Raphaël | job `rsr-miroir-perso`, bucket `rsr-perso` | lundi 4 h | Scaleway, seul |
| Copie de secours sur le NAS | PC de Raphaël, tâche « RSR - Archivage - Copie NAS » | chaque jour 10 h et à l'ouverture de session ; ne copie que si la dernière réussite a plus de 7 jours et si le NAS répond | Windows, seul |
| Archivage des projets de plus de 5 ans | PC de Raphaël, `archivage-annuel/Archiver-Dossier.ps1` | janvier, ou au fil de l'eau | Raphaël |

Trois copies de chaque document de travail : SharePoint (original), bucket miroir (cloud, versionné, corbeille 90 jours), NAS (local, instantanés). Les projets archivés : bucket `rsr-archives` (référence) et zone archives du NAS.

Personne n'a de machine à laisser allumée. Le cloud se sauvegarde sans le cabinet ; le NAS rattrape son retard dès que le PC de Raphaël est sur le réseau.

## 2. Chaque mois : 10 minutes de contrôle

Rendez-vous récurrent, première semaine du mois.

1. **Scaleway** > Serverless > Jobs > `rsr-miroir` > Exécutions : la dernière est `succeeded` et date de moins de 8 jours. Même contrôle sur `rsr-miroir-perso`.
2. **Scaleway** > Object Storage > `rsr-miroir` > `_inventaire/` : ouvrir le dernier fichier. Aucune ligne `ECHEC` ni `MANQUANT`. Les nouveaux sites du mois y figurent. Décider pour chaque nouveau site s'il doit être exclu (`EXCLUDE_SITES` dans la définition du job) ou rendu obligatoire (`MUST_SITES`).
3. **PC** : dans PowerShell,

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\RaphaeldeSaintRomain\OneDrive - Raphaël de Saint Romain Conseil et Investissement\Q- RSR C&I\R- Code\2511-Archivage Numérique\nas-pull\NasPull.ps1" -Action Check
```

   Les trois cibles à moins de 14 jours. Sinon, se mettre sur le réseau du cabinet et lancer `-Action Sync -Force`.
4. **Noter** le contrôle dans le README du projet (section Suivi), une ligne : date, résultat.

Que faire si un job est en échec : ouvrir le journal de l'exécution dans Scaleway, chercher `ERREUR` ou `ECHEC`. Les causes vues à ce jour et leurs remèdes sont dans `cloud-job/DEPLOIEMENT.md`. Un échec isolé n'est pas grave, la copie reprend au passage suivant ; deux échecs consécutifs demandent une intervention.

## 3. Chaque janvier : l'année N-5

En janvier 2027, l'année 2021. Détail dans `archivage-annuel/PROCEDURE.md`.

1. Lister les projets à archiver : préfixe de l'année N-5 dans Projets Passés et dans Projets M&A / 4 - Projets M&A passés. Fusionner d'abord les doublons (« X » et « X1 »).
2. Créer une clé Scaleway d'écriture temporaire (expiration 1 jour), l'enregistrer sur le PC sous `scw-ecriture`.
3. Pour chaque projet : Vérifier, Copier, Contrôler avec le script. La copie se fait côté Scaleway, du miroir vers `rsr-archives`.
4. Supprimer les projets archivés dans SharePoint.
5. Supprimer la clé et le remote `scw-ecriture`.
6. Profiter de la clé pour le ménage du bucket : supprimer les dossiers orphelins signalés dans le README.
7. Noter dans le README : année archivée, nombre de projets, volume.

Un projet peut aussi être archivé à tout moment, seul, par les mêmes étapes.

## 4. Chaque année : test de restauration

Sans test, une sauvegarde est une hypothèse. Une fois par an, en janvier avec l'archivage :

- **Depuis le cloud** : choisir un dossier au hasard dans `rsr-archives`, le télécharger avec `rclone copy scw-lecture:rsr-archives/Conseil/<dossier> C:\Restauration\` et ouvrir deux fichiers.
- **Depuis le NAS** : dans la console UniFi, restaurer un fichier depuis un instantané du partage Synchro_OneDrive.
- **Depuis une version** : dans la console Scaleway, bucket `rsr-miroir`, afficher les versions d'un fichier modifié récemment et en récupérer une ancienne.

Consigner les trois résultats dans le README.

## 5. Restaurer pour de vrai

| Situation | Où aller |
|---|---|
| Un fichier supprimé par erreur cette semaine | corbeille SharePoint (93 jours) |
| Un fichier supprimé ou écrasé il y a moins de 90 jours | bucket `rsr-miroir`, dossier `_corbeille/<date>/…`, ou versions de l'objet |
| Une bibliothèque entière, ou SharePoint indisponible | bucket `rsr-miroir` en lecture : `rclone copy scw-lecture:rsr-miroir/<site>/<bibliothèque> <destination>` |
| Le cloud indisponible | NAS, partage Synchro_OneDrive, même arborescence que le bucket |
| Un projet archivé | bucket `rsr-archives/Conseil` ou `/M&A`, ou NAS Sauvegarde_Projets_historiques |
| Un fichier du NAS effacé par la copie | `z-corbeille\<date>` sur le partage (90 jours), ou instantané UniFi |

## 6. Renouvellements et rappels

| Quoi | Quand | Où |
|---|---|---|
| Secret de l'application Entra « RSR Archivage » | expire 09/2028, rappel Claude et calendrier au 23/07/2028 | Entra, puis nouvelle version du secret Scaleway `entra-client-secret` |
| Script du job (`sync.sh`) | à chaque modification | nouvelle version du secret Scaleway `sync-sh`, puis « Run job » de contrôle |
| Image du job (`alpine:3.22`) | une fois par an | définition du job |
| rclone sur le PC | avec les mises à jour Windows / winget | `winget upgrade Rclone.Rclone` |

## 7. Limites connues

- Le NAS UniFi refuse les noms de fichiers de plus de 143 caractères (accents comptant double). Ces fichiers sont dans le cloud mais pas sur le NAS ; la liste est dans `%LOCALAPPDATA%\RSR-Archivage\fichiers-a-renommer.txt`. Les raccourcir dans SharePoint.
- Les instantanés du NAS peuvent être supprimés par un administrateur UniFi ; la protection contre un attaquant qui tient la console UniFi est le cloud versionné, pas le NAS.
- La clé d'écriture du job Scaleway peut supprimer des objets ; le versioning conserve 90 jours toute version supprimée ou écrasée. Pour aller plus loin, activer le verrouillage d'objets (Object Lock) sur `rsr-archives`.
- Le PC de Raphaël est le seul à alimenter le NAS. Un second PC du cabinet peut être équipé de la même tâche avec la même clé de lecture, sans conflit : le verrou et la règle des 7 jours s'en chargent.

## 8. Qui sait faire quoi

Ce dossier, le dépôt GitHub privé `rsrconseil/archivage-numerique` et les consoles Scaleway, Entra et UniFi suffisent à reprendre l'exploitation. Un suppléant doit avoir : accès à la console Scaleway (projet `rsr-archivage`), à la console UniFi, un compte administrateur Microsoft 365 pour Entra, et ce dépôt.
