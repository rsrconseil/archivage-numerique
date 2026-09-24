# Archivage numérique RSR Conseil

Sauvegarde et archivage des documents du cabinet. Architecture décidée le 23 septembre 2026 (voie A).

## Architecture

| Horizon | Stockage | Alimenté par |
|---|---|---|
| Moins de 5 ans, travail courant | SharePoint / OneDrive | les équipes |
| Moins de 5 ans, copie cloud | bucket Scaleway `rsr-miroir` (Standard, versioning, corbeille 90 j) | job Scaleway hebdomadaire à découverte automatique : tout site SharePoint existant ou futur est copié, sauf exclusion explicite. Dossier `cloud-job/` |
| Plus de 5 ans | bucket Scaleway `rsr-archives` (Standard), dossiers `Conseil/` et `M&A/` | copie côté Scaleway depuis le miroir, dossier `archivage-annuel/`, puis suppression dans SharePoint |
| OneDrive personnel de Raphaël | bucket Scaleway `rsr-perso` | second job, secret et bucket distincts |
| Copie de secours locale de tout | NAS UniFi 192.168.9.139, partages Synchro_OneDrive, Sauvegarde_Projets_historiques, Personal-Drive, instantanés quotidiens | tâche hebdomadaire sur le PC de Raphaël, dossier `nas-pull/` (à venir) |
| Archives Glacier de novembre 2025 | buckets `backup-rsrconseil` et `backup-projetsma` | plus alimentés, copie dormante |

Personne n'a de machine à laisser allumée : le job cloud est déclenché par Scaleway, le NAS reçoit sa copie quand le PC est sur le réseau du cabinet ou en VPN.

## Organisation du dossier

```
2511-Archivage Numérique/
├── README.md                     ce fichier
├── PROCEDURE-Archivage.md        rituels mensuel et annuel, restauration (à mettre à jour pour la voie A)
├── 2511 - Organisation de l'archivage.pptx   intention d'origine, novembre 2025
├── cloud-job/                    miroir SharePoint -> Scaleway, sans machine locale
│   ├── DEPLOIEMENT.md            pas à pas : Entra ID, Scaleway, premier lancement, contrôle mensuel
│   ├── sync.sh                   le job : découvre tous les sites via Microsoft Graph et les copie
│   ├── bibliotheques.json        état de référence des bibliothèques au 23/09/2026 (contrôle, pas configuration)
│   └── Get-DriveIds.ps1          outil de contrôle : ce que l'application Entra voit, et le contenu de chaque lecteur
├── archivage-annuel/             passer un projet du miroir aux archives (rituel annuel ou au fil de l'eau)
│   ├── PROCEDURE.md              le déroulé, la clé temporaire, l'année N-5 en boucle
│   └── Archiver-Dossier.ps1      Verifier / Copier (côté Scaleway) / Controler, puis suppression manuelle dans SharePoint
├── nas-pull/                     copie de secours : buckets -> partages NAS, depuis le PC
│   ├── INSTALLATION.md           clé lecture seule, remote rclone, première copie, tâche planifiée, contrôle mensuel
│   ├── NasPull.ps1               le script (Sync / Check / Status), ne copie que si la dernière réussite a plus de 7 jours
│   ├── nas-pull.json             les trois couples bucket -> partage UNC
│   └── Installer-Tache.ps1       crée la tâche planifiée « RSR - Archivage - Copie NAS »
└── legacy/                       les 12 .bat de 2025 et le script consolidé v2 (Archivage.ps1), remplacés de novembre 2025, conservés pour mémoire
```

## Où vivent les secrets

Nulle part dans ce dossier, ni dans git, ni dans OneDrive.

| Secret | Emplacement | Copie de secours |
|---|---|---|
| Secret de l'application Entra ID | Scaleway Secret Manager, secret `entra-client-secret` | gestionnaire de mots de passe de Raphaël (KeePass existant) |
| Clé API Scaleway du job | Secret Manager, secret `scw-secret-key` | idem |
| Clé API Scaleway du PC (lecture seule, pour nas-pull) | `%APPDATA%\rclone\rclone.conf` sur le PC | idem |

Le fichier `.gitignore` refuse `rclone.conf`, `*.env`, `*.key` et les journaux.

## Versionnement : ce dossier et GitHub

Ce dossier est la copie de travail. Il est dans OneDrive, donc déjà répliqué, mais OneDrive ne donne ni historique lisible ni comparaison entre versions.

Ce dossier est un dépôt git, poussé sur GitHub dans le dépôt **privé** [rsrconseil/archivage-numerique](https://github.com/rsrconseil/archivage-numerique) (créé le 24/09/2026). Elle sert à trois choses : historique des changements de configuration, relecture avant modification, et point de reprise si le dossier OneDrive est corrompu. Aucun secret n'y transite, les modèles ne contiennent que des espaces réservés.

Précaution connue : un dépôt git dans un dossier OneDrive peut voir ses fichiers internes synchronisés en cours d'écriture. C'est déjà le cas pour AI-CDD sans incident signalé. Si des erreurs git apparaissent, déplacer le dépôt hors de OneDrive et ne garder ici qu'un raccourci.

## Suivi des travaux

- [x] Diagnostic de l'existant (23/09/2026)
- [x] Choix de l'architecture, voie A
- [x] Job cloud à découverte automatique (`cloud-job/sync.sh`)
- [x] Application Entra ID créée, consentement accordé, 15 lecteurs vérifiés (23/09/2026)
- [ ] Contrôle du contenu à la racine des lecteurs (Get-DriveIds.ps1, section B)
- [x] Projet, buckets, règles de cycle de vie, clé sans suppression, secrets et job Scaleway (23/09/2026)
- [x] Premier lancement réduit sur Admin RSR Conseil : 1,5 Go copiés, seconde passe en 11 s, inventaire déposé (23/09/2026)
- [x] Exécutions complètes : v3 (jeton renouvelé), v3.1 (limitation de débit), v3.2 (sous-sites). Le 24/09/2026 : 32 bibliothèques OK, 6 sites exclus, Projets Passés copié (114 Go)
- [x] `nas-pull/` écrit et testé sur ce PC contre un bucket existant (23/09/2026)
- [x] `nas-pull/` : clé lecture seule, remote `scw-lecture`, tâche planifiée installée, première copie lancée le 24/09/2026 (en cours)
- [ ] Instantanés quotidiens sur les trois partages du NAS (console UniFi)
- [x] Amorçage : NAS réorganisé (Conseil 97, M&A 14), envoyé dans rsr-archives et rsr-perso, vérifié fichier par fichier, staging nettoyé (23-24/09/2026). Restent à arbitrer : Carso et Adcreches (versions NAS de 2021, SharePoint plus récent)
- [x] Premier dossier archivé avec `archivage-annuel/` : 2509 - Davitec x Platina - Low Energy (24/09/2026)
- [ ] Archiver les projets 2020 (dont Nuage) ; 2021 en janvier 2027
- [ ] Réécrire PROCEDURE-Archivage.md pour la voie A
- [ ] Test de restauration annuel, premier passage
- [x] Dépôt GitHub privé `rsrconseil/archivage-numerique`, premier commit poussé le 24/09/2026
