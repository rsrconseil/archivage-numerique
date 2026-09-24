<#
.SYNOPSIS
    Passe un dossier projet du miroir cloud vers les archives cloud (rituel annuel, ou au fil de l'eau).

.DESCRIPTION
    Le dossier vit sur SharePoint et se trouve donc déjà dans le bucket rsr-miroir. Le script :
      Verifier   compare la copie locale SharePoint (OneDrive sur ce PC) avec le miroir cloud : le miroir doit être à jour
      Copier     copie côté Scaleway, de rsr-miroir vers rsr-archives/<Categorie>/<Dossier> (rien ne transite par le PC)
      Controler  compare rsr-archives avec la copie locale : chaque fichier doit y être, même taille et empreinte
    Puis VOUS supprimez le dossier dans SharePoint (navigateur). Le job hebdomadaire le retirera du miroir
    (corbeille 90 jours), nas-pull le placera dans la zone archives du NAS et le retirera de la zone miroir.

    Nécessite un remote rclone avec droit d'écriture (scw-ecriture), clé temporaire créée pour l'occasion.
    Chaque étape est rejouable ; -WhatIf simule Copier.

.PARAMETER Site
    Nom du site tel qu'il apparaît dans le bucket (dossier de premier niveau) : "Projets conseil traditionnel",
    "Projets M&A", "Site racine"...
.PARAMETER Bibliotheque
    Nom de la bibliothèque dans le bucket (second niveau). "Documents" en général, "Projets Passés" sur le site racine.
.PARAMETER Dossier
    Chemin du dossier projet dans la bibliothèque, ex. "2509 - Performances Vignobles-PMO"
    ou "4 - Projets M&A passés/2012 - Nuage".
.PARAMETER Categorie
    Conseil ou M&A : sous-dossier de destination dans rsr-archives.
.PARAMETER Local
    Chemin local de la copie OneDrive du dossier, si le script ne le devine pas.

.EXAMPLE
    .\Archiver-Dossier.ps1 -Etape Verifier  -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
    .\Archiver-Dossier.ps1 -Etape Copier    -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil -WhatIf
    .\Archiver-Dossier.ps1 -Etape Copier    -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
    .\Archiver-Dossier.ps1 -Etape Controler -Site "Projets conseil traditionnel" -Dossier "2509 - Performances Vignobles-PMO" -Categorie Conseil
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [ValidateSet('Verifier', 'Copier', 'Controler')] [string]$Etape,
    [Parameter(Mandatory)] [string]$Site,
    [string]$Bibliotheque = 'Documents',
    [Parameter(Mandatory)] [string]$Dossier,
    [Parameter(Mandatory)] [ValidateSet('Conseil', 'M&A')] [string]$Categorie,
    [string]$Local,
    [string]$Remote = 'scw-ecriture:',
    [string]$SharePointLocal = "$env:USERPROFILE\Raphaël de Saint Romain Conseil et Investissement"
)
$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $env:LOCALAPPDATA 'RSR-Archivage\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$Nom = Split-Path $Dossier -Leaf
$Miroir   = "${Remote}rsr-miroir/$Site/$Bibliotheque/$Dossier"
$Archives = "${Remote}rsr-archives/$Categorie/$Nom"
$Journal  = Join-Path $LogDir 'archivage-dossiers.csv'

# Copie locale OneDrive : "<site> - <bibliothèque>" en général ; sur le site racine, "<bibliothèque> - Documents"
if (-not $Local) {
    $candidats = @("$SharePointLocal\$Site - $Bibliotheque\$Dossier", "$SharePointLocal\$Bibliotheque - Documents\$Dossier", "$SharePointLocal\$Site - General\$Dossier")
    $Local = $candidats | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $Local) { throw "Copie locale introuvable, passer -Local. Essayé :`n  " + ($candidats -join "`n  ") }
}
$remotes = (rclone listremotes) -split "`n" | ForEach-Object { $_.Trim() }
if ($remotes -notcontains $Remote) { throw "Remote $Remote absent : créer une clé temporaire et l'enregistrer (voir PROCEDURE)." }

$exclus = @('--exclude', 'desktop*.ini', '--exclude', '~$*', '--exclude', 'Thumbs.db')
Write-Host "Dossier   : $Dossier" -ForegroundColor Cyan
Write-Host "Local     : $Local"
Write-Host "Miroir    : $Miroir"
Write-Host "Archives  : $Archives"

function Write-Journal([string]$Resultat, [string]$Detail = '') {
    [pscustomobject]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Etape = $Etape; Dossier = "$Site/$Bibliotheque/$Dossier"; Cible = "$Categorie/$Nom"; Resultat = $Resultat; Detail = $Detail } |
        Export-Csv -Path $Journal -Append:(Test-Path $Journal) -NoTypeInformation -Encoding UTF8
}

switch ($Etape) {
    'Verifier' {
        $log = Join-Path $LogDir "archiver-verif-$Stamp.log"
        rclone check $Local $Miroir --one-way --size-only @exclus --log-file $log --log-level NOTICE
        if ($LASTEXITCODE -eq 0) { Write-Host "Le miroir cloud est à jour pour ce dossier : on peut copier." -ForegroundColor Green; Write-Journal OK }
        else { Write-Host "Le miroir cloud diffère de SharePoint (voir $log). Attendre la prochaine exécution du job, ou la lancer à la main, puis recommencer." -ForegroundColor Red; Write-Journal 'DIFFERENT' $log; exit 1 }
    }
    'Copier' {
        if (Test-Path -LiteralPath $Local) { $n = (Get-ChildItem -LiteralPath $Local -Recurse -File | Measure-Object).Count; Write-Host "$n fichiers à copier côté Scaleway (aucun transfert par le PC)." }
        $log = Join-Path $LogDir "archiver-copie-$Stamp.log"
        $dry = if ($WhatIfPreference) { '--dry-run' } else { $null }
        rclone copy $Miroir $Archives @exclus --transfers 8 --checkers 16 --retries 3 --log-file $log --log-level INFO --stats 1m --stats-one-line --progress $dry
        if ($LASTEXITCODE -eq 0) { Write-Host "Copie terminée." -ForegroundColor Green; if (-not $dry) { Write-Journal OK } }
        else { Write-Host "ECHEC de la copie (voir $log)." -ForegroundColor Red; Write-Journal 'ECHEC' $log; exit 1 }
    }
    'Controler' {
        $log = Join-Path $LogDir "archiver-controle-$Stamp.log"
        rclone check $Local $Archives --one-way @exclus --log-file $log --log-level NOTICE
        if ($LASTEXITCODE -eq 0) {
            Write-Journal OK
            Write-Host "Archives conformes : chaque fichier local est dans $Archives." -ForegroundColor Green
            Write-Host ""
            Write-Host "Dernière étape, à faire à la main : supprimer le dossier « $Nom » dans SharePoint (navigateur)." -ForegroundColor Yellow
            Write-Host "  Il restera 93 jours dans la corbeille SharePoint, 90 jours dans la corbeille du bucket miroir," -ForegroundColor Yellow
            Write-Host "  et définitivement dans rsr-archives/$Categorie puis dans la zone archives du NAS." -ForegroundColor Yellow
        } else { Write-Host "DIFFERENCES entre la copie locale et les archives (voir $log). Ne pas supprimer de SharePoint." -ForegroundColor Red; Write-Journal 'DIFFERENT' $log; exit 1 }
    }
}
