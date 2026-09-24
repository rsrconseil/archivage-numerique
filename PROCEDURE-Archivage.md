# Procédure d'archivage numérique RSR Conseil

Version 2 — 23 septembre 2026. Remplace les 12 fichiers `.bat` de novembre 2025 par un script unique, `Archivage.ps1`, piloté par `archivage.json`.

## 1. Architecture (inchangée)

| Horizon | Stockage principal | Stockage secondaire |
|---|---|---|
| Moins de 5 ans | OneDrive / SharePoint (7 bibliothèques) | Disque local du serveur RSR (`X:`), copie mensuelle |
| Plus de 5 ans | Disque local du serveur RSR (`X:\Projets Passés`) | Scaleway Glacier fr-par, un zip par projet |

Buckets Scaleway : `backup-rsrconseil` (conseil) et `backup-projetsma` (M&A). Un zip par dossier projet, nommé `AAMM - Client - Sujet.zip`.

Les fichiers de ce dossier (`R- Code\2511-Archivage Numérique`) sont la **seule source de vérité**. La copie dans `Admin RSR Conseil - General\7- IT` doit être supprimée ou remplacée par un raccourci.

## 2. Ce qui a changé par rapport au bricolage de 2025

| Avant | Maintenant | Pourquoi |
|---|---|---|
| 7 scripts `sync-*.bat` | `Archivage.ps1 -Action Sync` | Une seule commande, une seule config |
| `rclone sync` sans filet | `--backup-dir X:\z-corbeille\<lib>\<date>` | Un fichier supprimé ou chiffré sur OneDrive est **déplacé** dans la corbeille au lieu d'être perdu. C'est la vraie protection anti-ransomware. Rétention 90 jours. |
| Logs écrasés / illisibles | Un log par exécution + `archivage-journal.csv` | On sait qui a tourné, quand, et avec quel résultat |
| Aucune vérification | `rclone check` après chaque envoi Glacier | Les zips ne sont supprimés que si le bucket est conforme |
| Lecteurs non vérifiés | Contrôle des lecteurs et des remotes avant tout | Un `X:` débranché ne donne plus une synchro vide |
| `Compress-Archive` | 7-Zip si installé | Limite de 2 Go levée (le zip Mediapost fait déjà 2,0 Go) |
| Aucun garde-fou | Alerte si un dossier < 5 ans est dans le staging | Évite d'envoyer un projet actif en Glacier |
| Code de sortie ignoré | 0 = OK, 1 = échec | Le Planificateur de tâches remonte l'échec |

## 3. Installation sur le serveur RSR Conseil (une fois)

1. Copier `Archivage.ps1` et `archivage.json` dans `C:\RSR\Archivage\` sur le serveur.
2. Installer 7-Zip : `winget install 7zip.7zip`.
3. Vérifier que les 8 remotes rclone existent : `rclone listremotes` doit lister `onedrive-admin`, `onedrive-projets-conseil`, `onedrive-projets-ma`, `onedrive-propositions-commerciales`, `onedrive-vie-cabinet`, `onedrive-je-vends-ma-pme`, `onedrive-perso-rsr`, `remote-sw-paris`.
4. Créer les dossiers `X:\z-logs`, `X:\z-corbeille`, `X:\Projets Passés`, `X:\Projets M&A passés`.
5. Lancer le contrôle :

```powershell
powershell -ExecutionPolicy Bypass -File C:\RSR\Archivage\Archivage.ps1 -Action Check
```

6. Première synchro en simulation, puis pour de vrai :

```powershell
powershell -ExecutionPolicy Bypass -File C:\RSR\Archivage\Archivage.ps1 -Action Sync -DryRun
powershell -ExecutionPolicy Bypass -File C:\RSR\Archivage\Archivage.ps1 -Action Sync
```

7. Créer la tâche planifiée mensuelle (le 1er à 3 h, compte de service ou session de Raphaël, « exécuter même si l'utilisateur n'est pas connecté ») :

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\RSR\Archivage\Archivage.ps1 -Action Sync'
$trigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth 1 -At 03:00
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -StartWhenAvailable
Register-ScheduledTask -TaskName 'RSR - Archivage - Sync mensuelle' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest
```

## 4. Chaque mois (5 minutes, dans les jours qui suivent le 1er)

1. Sur le serveur : `Archivage.ps1 -Action Check`.
2. Lire la section « Dernières exécutions » : chaque bibliothèque doit être `OK` et dater de moins de 40 jours. Toute ligne `ECHEC` renvoie vers le log à ouvrir.
3. Si le jeton OneDrive a expiré (message `invalid_grant` dans le log) : `rclone config reconnect <remote>:` puis relancer `-Action Sync -Perimetre <nom>`.
4. Consigner le contrôle (date + résultat) dans le journal d'exploitation IT, ou simplement garder le CSV.

## 5. Chaque année, en janvier (archivage de l'année N-5)

Exemple : en janvier 2027, on archive les projets dont le préfixe est `21xx`.

1. Vérifier que la synchro de décembre est `OK` (`-Action Check`).
2. Sur OneDrive, déplacer les dossiers de l'année N-5 :
   - conseil : de `Projets Passés` vers `Y:\temp-conseil` (via l'explorateur du serveur)
   - M&A : de `Projets M&A\4 - Projets M&A passés` vers `Y:\temp-ma`
3. Simulation : `Archivage.ps1 -Action Archive -DryRun`. Lire les avertissements (dossier trop récent, 7-Zip absent).
4. Exécution : `Archivage.ps1 -Action Archive`. Le script enchaîne zip, envoi Glacier, `rclone check`, déplacement vers `X:\Projets Passés` et suppression des zips. S'il s'arrête avec `ECHEC`, rien n'est supprimé : corriger et relancer, les zips déjà envoyés sont ignorés.
5. Vérifier dans la console Scaleway que le nombre d'objets a augmenté du nombre de dossiers archivés.
6. Supprimer les dossiers sources de OneDrive (ils sont désormais sur `X:` et en Glacier).
7. Noter dans le journal IT : année archivée, nombre de dossiers, volume.

## 6. Restauration (à tester une fois par an)

Glacier n'est pas lisible directement : il faut d'abord demander le rapatriement, attendre quelques heures, puis télécharger.

```powershell
# 1. Demander le rapatriement (durée de disponibilité : 7 jours)
rclone backend restore remote-sw-paris:backup-rsrconseil/"1810 - Lamarque Sogy Bois.zip" -o lifetime=7

# 2. Vérifier l'état (ongoing-request = false quand c'est prêt)
rclone backend restore-status remote-sw-paris:backup-rsrconseil/"1810 - Lamarque Sogy Bois.zip"

# 3. Télécharger
rclone copy remote-sw-paris:backup-rsrconseil/"1810 - Lamarque Sogy Bois.zip" C:\Restauration\
```

Test annuel : restaurer un zip au hasard, l'ouvrir, vérifier qu'un fichier Excel ou PowerPoint s'ouvre. Consigner le résultat.

## 7. Périmètre non couvert aujourd'hui (à décider)

Ces bibliothèques SharePoint sont synchronisées sur les postes mais **aucun script ne les sauvegarde** :

- `Projets Passés - Documents` (188 dossiers, 2016 à 2026, dont 15 dossiers `20xx` qui auraient dû partir en Glacier fin 2025)
- `Datarooms RSR Conseil`, `CODIR`, et les Teams de projet (`Ergea-Projet Paros`, `2606 - Projet Ossoul`, `2606 - Ixo PE - Projet Clear`, `2606 - Projet Bubble`, `2609 - Projet Feed - VDD`)

Pour chacune : soit l'ajouter à `syncs` dans `archivage.json` (il faut créer le remote rclone correspondant), soit acter par écrit qu'elle n'est pas sauvegardée.

## 8. Sécurité des accès

- La clé Scaleway dans `rclone.conf` a aujourd'hui tous les droits, y compris la suppression. Créer dans la console Scaleway (IAM) une application dédiée « archivage » avec une politique limitée à `ObjectStorageObjectsWrite` + `ObjectStorageObjectsRead` + `ObjectStorageBucketsRead` sur les deux buckets, sans droit de suppression, et l'utiliser sur le serveur.
- Activer le **versioning** sur les deux buckets : une suppression ou un écrasement malveillant reste récupérable.
- `rclone.conf` contient des secrets en clair. Il ne doit exister que sur le serveur et sur le poste de Raphaël, jamais dans OneDrive.

## 9. Anomalies constatées le 23 septembre 2026

- Sur ce PC, seuls 2 remotes rclone sur 8 sont configurés et le jeton `onedrive-admin` est expiré : les synchros ne peuvent tourner que depuis le serveur. Aucune tâche planifiée n'existe sur ce PC.
- Dernier envoi Glacier : 17 novembre 2025 (chargement initial, 75 zips, 16,6 Go). L'archivage de l'année 2020, dû en janvier 2026, n'a pas été fait.
- Doublons dans les buckets, probablement des dossiers en double sur SharePoint : `1811 - Egaho (acquéreur Pascal Prat)` et `...1`, `1911 - Glaces du Verger` et `...1`, `1912 - France Designer Inox` et `...1`. Les mêmes doublons `Trio CVM1`, `B for Doc1`, `EMAM Groupe1`, etc. existent dans `4 - Projets M&A passés`. À fusionner avant l'archivage 2027.
