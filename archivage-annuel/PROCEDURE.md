# Archiver un dossier projet (rituel annuel, ou au fil de l'eau)

Un projet archivé quitte SharePoint et le miroir, et vit désormais dans `rsr-archives` (cloud) et dans la zone archives du NAS. Le mécanisme est le même pour un dossier isolé et pour l'archivage de l'année N-5 en janvier : on le répète par dossier.

## Ce qui se passe, dans l'ordre

1. Le dossier est sur SharePoint, donc dans le bucket `rsr-miroir` depuis le dernier passage du job.
2. `Archiver-Dossier.ps1 -Etape Verifier` confirme que le miroir est à jour pour ce dossier (comparaison avec la copie OneDrive du PC, sans télécharger).
3. `-Etape Copier` copie le dossier **côté Scaleway**, de `rsr-miroir` vers `rsr-archives/<Conseil ou M&A>/<dossier>`. Rien ne transite par le PC, c'est rapide même pour des dizaines de Go.
4. `-Etape Controler` vérifie que chaque fichier est bien dans les archives, taille et empreinte.
5. **Vous supprimez le dossier dans SharePoint**, dans le navigateur. Filets de sécurité : corbeille SharePoint 93 jours, corbeille du bucket miroir 90 jours.
6. Le lundi suivant, le job retire le dossier du miroir. À la copie NAS suivante, nas-pull le fait apparaître dans `Sauvegarde_Projets_historiques\<Conseil ou M&A>\` et le retire de `Synchro_OneDrive` (corbeille NAS 90 jours).

## Avant de commencer : une clé d'écriture temporaire

Le PC ne garde qu'une clé en lecture seule. Pour archiver, créer une clé qui expire le jour même :

1. Scaleway > IAM > Applications > `job-archivage` > Clés API > Générer, description `archivage-<date>`, expiration à 1 jour.
2. Sur le PC :

```powershell
rclone config create scw-ecriture s3 provider=Scaleway region=fr-par endpoint=s3.fr-par.scw.cloud acl=private no_check_bucket=true access_key_id=<ACCESS_KEY> secret_access_key=<SECRET_KEY>
```

3. Après l'archivage : `rclone config delete scw-ecriture`, et supprimer la clé dans IAM si elle n'a pas encore expiré.

## Un dossier

Exemple pour un projet de la bibliothèque Projets conseil traditionnel :

```powershell
cd "C:\Users\RaphaeldeSaintRomain\OneDrive - Raphaël de Saint Romain Conseil et Investissement\Q- RSR C&I\R- Code\2511-Archivage Numérique\archivage-annuel"
.\Archiver-Dossier.ps1 -Etape Verifier  -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
.\Archiver-Dossier.ps1 -Etape Copier    -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
.\Archiver-Dossier.ps1 -Etape Controler -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
```

Où trouver les paramètres : `-Site` et le second niveau sont les deux premiers dossiers du chemin dans le bucket miroir (`Projets conseil traditionnel/Documents/…`). Pour un projet M&A passé : `-Site "Projets M&A" -Dossier "4 - Projets M&A passés/2012 - Nuage" -Categorie M&A`. Pour Projets Passés, qui est un sous-site du site racine, le site est `Site racine/Projets Passés` et la bibliothèque `Documents` : `-Site "Site racine/Projets Passés" -Dossier "2101 - RSR - PDM" -Categorie Conseil -Local "$env:USERPROFILE\Raphaël de Saint Romain Conseil et Investissement\Projets Passés - Documents1 - RSR - PDM"` (le paramètre `-Local` est nécessaire pour les sous-sites, le script ne devine pas leur dossier OneDrive).

Chaque étape écrit une ligne dans `%LOCALAPPDATA%\RSR-Archivage\logs\archivage-dossiers.csv` : c'est le registre de ce qui a été archivé, quand, et avec quel résultat.

## L'année N-5, en janvier

1. Lister les candidats : dans SharePoint, les dossiers dont le préfixe est l'année N-5 (en janvier 2027 : `21xx`), dans Projets Passés et dans Projets M&A / 4 - Projets M&A passés. Fusionner avant les doublons du type « Trio CVM » et « Trio CVM1 ».
2. Créer la clé temporaire.
3. Pour chaque dossier, les trois étapes ci-dessus. Une boucle PowerShell fait l'affaire pour une liste :

```powershell
foreach ($d in @('2101 - RSR - PDM','2101 - VMF - Projet Colisée')) {
  foreach ($e in 'Verifier','Copier','Controler') {
    .\Archiver-Dossier.ps1 -Etape $e -Site 'Site racine/Projets Passés' -Dossier $d -Categorie Conseil -Local "$env:USERPROFILE\Raphaël de Saint Romain Conseil et Investissement\Projets Passés - Documents\$d"
    if ($LASTEXITCODE -ne 0) { Write-Host "ARRET sur $d" -ForegroundColor Red; break }
  }
}
```

4. Supprimer les dossiers archivés dans SharePoint.
5. Supprimer la clé et le remote.
6. Noter dans le README la date et le nombre de dossiers archivés.

## Ce que le script refuse

- Copier si le miroir diffère de SharePoint : attendre ou lancer le job à la main, puis recommencer.
- Déclarer conforme si un fichier manque ou diffère dans les archives : ne rien supprimer dans SharePoint tant que `Controler` n'est pas vert.
