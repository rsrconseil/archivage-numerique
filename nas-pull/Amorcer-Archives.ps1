<#
.SYNOPSIS
    Amorçage à usage unique : réorganise les archives présentes sur le NAS, les envoie dans
    le bucket rsr-archives, copie Photos et archives Outlook dans rsr-perso, puis (sur demande)
    nettoie le staging de 2025.

.DESCRIPTION
    Sources sur \\192.168.9.139\Sauvegarde_Projets_historiques (état du 23/09/2026) :
      Conseil <- "Projets Passés 2016-2019" (62) + temp-conseil, sauf les dossiers encore présents sur SharePoint
      M&A     <- "Projets M&A 2018-2019" (14)
      Doublons : les dossiers de temp-conseil et upload-ma qui existent encore sur SharePoint
                 (les projets 2020, préparés en 2025 pour l'archivage mais jamais retirés de SharePoint,
                 et 1609 - INDEFI-Carso). SharePoint est la référence : ils seront archivés depuis le
                 bucket rsr-miroir par le rituel annuel. Ici, ils sont comparés à SharePoint (Doublons),
                 puis supprimés du NAS s'ils sont identiques (Nettoyer). Un doublon différent est conservé et signalé.
      upload-conseil : 42 zips redondants, supprimés à l'étape Nettoyer
    Sur \\192.168.9.139\Personal-Drive : Photos\ et *.pst -> rsr-perso (copie, jamais déplacés)

    Étapes, toutes rejouables, toujours en simulation d'abord (-WhatIf) :
      Doublons     compare chaque dossier NAS ayant un homonyme sur SharePoint (copie locale synchronisée du PC)
      Reorganiser  déplace les dossiers projet dans Conseil\ et M&A\ sur le NAS (renommage, instantané), doublons exclus
      Envoyer      rclone copy Conseil\ et M&A\ -> rsr-archives ; Photos et .pst -> rsr-perso
      Verifier     rclone check NAS -> bucket, sens unique : chaque fichier du NAS est dans le bucket
      Nettoyer     supprime upload-conseil\*.zip et les dossiers sources vidés (exige Verifier OK)

    Un remote rclone avec droit d'écriture est nécessaire pour Envoyer : voir INSTALLATION.md, « Amorçage ».

.EXAMPLE
    .\Amorcer-Archives.ps1 -Etape Doublons
    .\Amorcer-Archives.ps1 -Etape Reorganiser -WhatIf
    .\Amorcer-Archives.ps1 -Etape Reorganiser
    .\Amorcer-Archives.ps1 -Etape Envoyer -WhatIf
    .\Amorcer-Archives.ps1 -Etape Envoyer
    .\Amorcer-Archives.ps1 -Etape Verifier
    .\Amorcer-Archives.ps1 -Etape Nettoyer -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [ValidateSet('Doublons', 'Reorganiser', 'Envoyer', 'Verifier', 'Nettoyer')] [string]$Etape,
    [string]$RemoteEcriture = 'scw-ecriture:',
    [string]$Nas = '192.168.9.139',
    # Copie locale des bibliothèques SharePoint synchronisées par OneDrive sur ce PC
    [string]$SharePointLocal = "$env:USERPROFILE\Raphaël de Saint Romain Conseil et Investissement"
)
$ErrorActionPreference = 'Stop'
$H  = "\\$Nas\Sauvegarde_Projets_historiques"
$PD = "\\$Nas\Personal-Drive"
$LogDir = Join-Path $env:LOCALAPPDATA 'RSR-Archivage\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$Marqueur = Join-Path $LogDir 'amorcage-verifie.ok'
$MarqueurDoublons = Join-Path $LogDir 'amorcage-doublons.json'

# Où chercher l'original SharePoint d'un dossier du staging
$Originaux = @{
    "$H\temp-conseil" = "$SharePointLocal\Projets Passés - Documents"
    "$H\upload-ma"    = "$SharePointLocal\Projets M&A - Documents\4 - Projets M&A passés"
}
function Get-Doublons {
    # ConvertFrom-Json (PowerShell 5.1) renvoie le tableau JSON comme un seul objet : on l'énumère élément par élément
    if (-not (Test-Path $MarqueurDoublons)) { return }
    $j = Get-Content $MarqueurDoublons -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($x in $j) { $x }
}

$Plan = @(
    @{ Source = "$H\Projets Passés 2016-2019"; Cible = "$H\Conseil" },
    @{ Source = "$H\temp-conseil";             Cible = "$H\Conseil" },
    @{ Source = "$H\Projets M&A 2018-2019";    Cible = "$H\M&A" }
)

if (-not (Test-Path $H)) { throw "Partage inaccessible : $H (NAS hors réseau ?)" }

switch ($Etape) {

    'Doublons' {
        $res = @()
        foreach ($src in $Originaux.Keys) {
            $ref = $Originaux[$src]
            if (-not (Test-Path $src)) { continue }
            if (-not (Test-Path $ref)) { throw "Copie locale SharePoint introuvable : $ref (OneDrive synchronisé ?)" }
            foreach ($d in Get-ChildItem $src -Directory) {
                $orig = Join-Path $ref $d.Name
                if (-not (Test-Path -LiteralPath $orig)) { continue }
                $log = Join-Path $LogDir ("amorcage-doublon-{0}.log" -f ($d.Name -replace '[^\w\-]', '_'))
                rclone check $d.FullName $orig --one-way --size-only --exclude 'desktop*.ini' --exclude '~$*' --exclude 'Thumbs.db' --log-file $log --log-level NOTICE 2>$null
                $verdict = if ($LASTEXITCODE -eq 0) { 'IDENTIQUE' } else { 'DIFFERENT' }
                $res += [pscustomobject]@{ Dossier = $d.FullName; Original = $orig; Verdict = $verdict; Log = $log }
                Write-Host ("  {0,-10} {1}" -f $verdict, $d.Name) -ForegroundColor $(if ($verdict -eq 'IDENTIQUE') { 'Green' } else { 'Yellow' })
            }
        }
        ConvertTo-Json @($res) | Set-Content $MarqueurDoublons -Encoding UTF8
        $nId = @($res | Where-Object Verdict -eq 'IDENTIQUE').Count; $nDf = @($res | Where-Object Verdict -eq 'DIFFERENT').Count
        Write-Host "Doublons : $nId identiques (supprimés au Nettoyer), $nDf différents (conservés, à arbitrer à la main)." -ForegroundColor Cyan
    }

    'Reorganiser' {
        $doublons = @(Get-Doublons | ForEach-Object { $_.Dossier })
        if ($doublons.Count -eq 0 -and (Test-Path "$H\temp-conseil")) { throw "Lancer d'abord l'étape Doublons." }
        $n = 0; $collisions = 0
        foreach ($p in $Plan) {
            if (-not (Test-Path $p.Source)) { Write-Host "absent, ignoré : $($p.Source)" -ForegroundColor Yellow; continue }
            if (-not (Test-Path $p.Cible)) { if ($PSCmdlet.ShouldProcess($p.Cible, 'créer')) { New-Item -ItemType Directory -Path $p.Cible | Out-Null } }
            foreach ($d in Get-ChildItem $p.Source -Directory) {
                if ($doublons -contains $d.FullName) { Write-Host "doublon SharePoint, laissé en place : $($d.Name)" -ForegroundColor DarkGray; continue }
                $dest = Join-Path $p.Cible $d.Name
                if (Test-Path $dest) { Write-Host "COLLISION, laissé en place : $($d.FullName)" -ForegroundColor Red; $collisions++; continue }
                if ($PSCmdlet.ShouldProcess($d.FullName, "déplacer vers $($p.Cible)")) { Move-Item -LiteralPath $d.FullName -Destination $dest }
                $n++
            }
            Get-ChildItem $p.Source -File -Filter 'desktop*.ini' | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'supprimer fichier parasite')) { Remove-Item -LiteralPath $_.FullName -Force }
            }
        }
        Write-Host "Réorganisation : $n dossier(s) déplacé(s), $collisions collision(s)." -ForegroundColor Cyan
        foreach ($c in "$H\Conseil", "$H\M&A") { if (Test-Path $c) { Write-Host ("  {0,-8} {1} projets" -f (Split-Path $c -Leaf), (Get-ChildItem $c -Directory).Count) } }
    }

    'Envoyer' {
        $remotes = (rclone listremotes) -split "`n" | ForEach-Object { $_.Trim() }
        if ($remotes -notcontains $RemoteEcriture) { throw "Remote $RemoteEcriture absent. Voir INSTALLATION.md, « Amorçage »." }
        $dry = if ($WhatIfPreference) { '--dry-run' } else { $null }
        $envois = @(
            @{ Src = "$H\Conseil";              Dst = "${RemoteEcriture}rsr-archives/Conseil" },
            @{ Src = "$H\M&A";                  Dst = "${RemoteEcriture}rsr-archives/M&A" },
            @{ Src = "$PD\Photos";              Dst = "${RemoteEcriture}rsr-perso/Photos" },
            @{ Src = "$PD\RSR-Archive.pst";     Dst = "${RemoteEcriture}rsr-perso/" },
            @{ Src = "$PD\RSR-Archive-auto.pst"; Dst = "${RemoteEcriture}rsr-perso/" }
        )
        foreach ($e in $envois) {
            if (-not (Test-Path -LiteralPath $e.Src)) { Write-Host "absent, ignoré : $($e.Src)" -ForegroundColor Yellow; continue }
            $log = Join-Path $LogDir ("amorcage-envoi-{0}-{1}.log" -f ((Split-Path $e.Src -Leaf) -replace '[^\w\-]', '_'), $Stamp)
            Write-Host "--- $($e.Src)  ->  $($e.Dst)" -ForegroundColor Cyan
            $args = @('copy', $e.Src, $e.Dst, '--exclude', 'desktop*.ini', '--exclude', '~$*', '--exclude', 'Thumbs.db',
                      '--transfers', '4', '--checkers', '8', '--retries', '3', '--low-level-retries', '10',
                      '--s3-chunk-size', '64M', '--s3-upload-concurrency', '4',
                      '--progress', '--stats', '1m', '--stats-one-line', '--log-file', $log, '--log-level', 'INFO')
            if ($dry) { $args += $dry }
            rclone @args
            if ($LASTEXITCODE -ne 0) { Write-Host "ECHEC (rc=$LASTEXITCODE), voir $log" -ForegroundColor Red } else { Write-Host "OK" -ForegroundColor Green }
        }
    }

    'Verifier' {
        $ok = $true
        foreach ($v in @(@{ Src = "$H\Conseil"; Dst = "${RemoteEcriture}rsr-archives/Conseil" },
                          @{ Src = "$H\M&A";     Dst = "${RemoteEcriture}rsr-archives/M&A" },
                          @{ Src = "$PD\Photos"; Dst = "${RemoteEcriture}rsr-perso/Photos" })) {
            $log = Join-Path $LogDir ("amorcage-verif-{0}-{1}.log" -f ((Split-Path $v.Src -Leaf) -replace '[^\w\-]', '_'), $Stamp)
            Write-Host "--- vérification $($v.Src)" -ForegroundColor Cyan
            rclone check $v.Src $v.Dst --one-way --exclude 'desktop*.ini' --exclude '~$*' --exclude 'Thumbs.db' --log-file $log --log-level NOTICE
            if ($LASTEXITCODE -ne 0) { $ok = $false; Write-Host "DIFFERENCES, voir $log" -ForegroundColor Red } else { Write-Host "identique" -ForegroundColor Green }
        }
        foreach ($f in 'RSR-Archive.pst', 'RSR-Archive-auto.pst') {
            $loc = (Get-Item -LiteralPath "$PD\$f").Length
            $dist = (rclone lsjson "${RemoteEcriture}rsr-perso/$f" | ConvertFrom-Json | Select-Object -First 1).Size
            if ($loc -eq $dist) { Write-Host "$f : taille identique ($loc)" -ForegroundColor Green } else { $ok = $false; Write-Host "$f : local $loc, cloud $dist" -ForegroundColor Red }
        }
        if ($ok) { Get-Date | Set-Content $Marqueur; Write-Host "Vérification complète OK. L'étape Nettoyer est autorisée." -ForegroundColor Green }
        else { Remove-Item $Marqueur -ErrorAction SilentlyContinue; Write-Host "Vérification en échec : ne pas nettoyer." -ForegroundColor Red; exit 1 }
    }

    'Nettoyer' {
        if (-not (Test-Path $Marqueur)) { throw "L'étape Verifier n'a pas été passée avec succès : nettoyage refusé." }
        foreach ($dbl in Get-Doublons) {
            if ($dbl.Verdict -ne 'IDENTIQUE') { Write-Host "doublon DIFFERENT conservé, à arbitrer : $($dbl.Dossier)" -ForegroundColor Yellow; continue }
            if (-not (Test-Path -LiteralPath $dbl.Dossier)) { continue }
            if ($PSCmdlet.ShouldProcess($dbl.Dossier, 'supprimer (identique à SharePoint)')) { Remove-Item -LiteralPath $dbl.Dossier -Recurse -Force }
            Write-Host "supprimé (doublon identique) : $($dbl.Dossier)"
        }
        $cibles = @("$H\upload-conseil", "$H\upload-ma", "$H\temp-conseil", "$H\temp-ma", "$H\Projets Passés 2016-2019", "$H\Projets M&A 2018-2019")
        foreach ($c in $cibles) {
            if (-not (Test-Path $c)) { continue }
            $restant = @(Get-ChildItem $c -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.Extension -ne '.zip' -and $_.Name -notlike 'desktop*.ini' })
            if ($restant.Count -gt 0) { Write-Host "NON supprimé, contient encore $($restant.Count) fichier(s) (doublons différents ?) : $c" -ForegroundColor Yellow; continue }
            if ($PSCmdlet.ShouldProcess($c, 'supprimer (zips et dossiers vides)')) { Remove-Item -LiteralPath $c -Recurse -Force }
            Write-Host "supprimé : $c"
        }
    }
}
