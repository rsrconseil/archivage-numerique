<#
.SYNOPSIS
    Archivage numérique RSR Conseil : un seul script, quatre actions.

.DESCRIPTION
    Remplace les 12 fichiers .bat. Toute la configuration est dans archivage.json.

      Sync     : sauvegarde mensuelle OneDrive -> disque local (rclone sync + corbeille datée)
      Archive  : archivage annuel des projets > 5 ans (zip -> Scaleway Glacier -> vérification)
      Check    : contrôle de cohérence sans rien modifier (lecteurs, remotes, dernières synchros, buckets)
      Status   : affiche les dernières lignes du journal

    Chaque exécution écrit une ligne dans le journal CSV (date, action, cible, résultat, durée).
    Le code de sortie du script est 0 si tout a réussi, 1 sinon (exploitable par le Planificateur).

.EXAMPLE
    .\Archivage.ps1 -Action Check
    .\Archivage.ps1 -Action Sync -DryRun
    .\Archivage.ps1 -Action Sync
    .\Archivage.ps1 -Action Archive -Perimetre conseil
    .\Archivage.ps1 -Action Status
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Sync', 'Archive', 'Check', 'Status')]
    [string]$Action,

    # Limiter à une seule cible (nom d'une entrée "syncs" ou "archives" du JSON)
    [string]$Perimetre,

    # Simulation : rclone --dry-run, aucun fichier écrit ni supprimé
    [switch]$DryRun,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'archivage.json')
)

$ErrorActionPreference = 'Stop'
$script:Echecs = 0
$script:Horodatage = Get-Date -Format 'yyyyMMdd-HHmm'

# ---------------------------------------------------------------- utilitaires

function Write-Journal {
    param([string]$Action, [string]$Cible, [string]$Resultat, [double]$Secondes, [string]$Detail = '')
    $ligne = [pscustomobject]@{
        Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Machine  = $env:COMPUTERNAME
        Action   = $Action
        Cible    = $Cible
        Resultat = $Resultat
        Secondes = [math]::Round($Secondes)
        Detail   = $Detail
    }
    $dir = Split-Path $Config.journal
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existe = Test-Path $Config.journal
    $ligne | Export-Csv -Path $Config.journal -Append:$existe -NoTypeInformation -Encoding UTF8
    $couleur = if ($Resultat -eq 'OK') { 'Green' } elseif ($Resultat -eq 'SIMULATION') { 'Cyan' } else { 'Red' }
    Write-Host ("[{0}] {1,-8} {2,-18} {3,-10} {4}s {5}" -f $ligne.Date, $Action, $Cible, $Resultat, $ligne.Secondes, $Detail) -ForegroundColor $couleur
    if ($Resultat -ne 'OK' -and $Resultat -ne 'SIMULATION') { $script:Echecs++ }
}

function Invoke-Rclone {
    # Lance rclone, renvoie le code de sortie. La sortie console va dans le log et à l'écran.
    param([string[]]$Arguments, [string]$LogFile)
    $args = @($Arguments) + @('--log-file', $LogFile, '--log-level', 'INFO', '--stats', '5m', '--stats-one-line')
    if ($DryRun) { $args += '--dry-run' }
    Write-Verbose ("rclone " + ($args -join ' '))
    & $Config.rclone @args
    return $LASTEXITCODE
}

function Test-Prerequis {
    # Renvoie $true si l'environnement permet d'exécuter l'action. Ne modifie rien.
    param([switch]$Syncs, [switch]$Archives)
    $ok = $true
    if (-not (Get-Command $Config.rclone -ErrorAction SilentlyContinue)) {
        Write-Host "ERREUR : rclone introuvable ($($Config.rclone))" -ForegroundColor Red; return $false
    }
    $remotes = (& $Config.rclone listremotes) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($s in $(if ($Syncs) { Select-Cibles $Config.syncs } else { @() })) {
        if ($remotes -notcontains $s.remote) { Write-Host "ERREUR : remote rclone absent : $($s.remote) (sync $($s.nom))" -ForegroundColor Red; $ok = $false }
        $racine = [System.IO.Path]::GetPathRoot($s.dest)
        if (-not (Test-Path $racine)) { Write-Host "ERREUR : lecteur non monté : $racine (sync $($s.nom))" -ForegroundColor Red; $ok = $false }
    }
    foreach ($a in $(if ($Archives) { Select-Cibles $Config.archives } else { @() })) {
        $remote = ($a.bucket -split ':')[0] + ':'
        if ($remotes -notcontains $remote) { Write-Host "ERREUR : remote rclone absent : $remote (archive $($a.nom))" -ForegroundColor Red; $ok = $false }
        foreach ($p in @($a.staging, $a.zipDir)) {
            $racine = [System.IO.Path]::GetPathRoot($p)
            if (-not (Test-Path $racine)) { Write-Host "ERREUR : lecteur non monté : $racine (archive $($a.nom))" -ForegroundColor Red; $ok = $false }
        }
    }
    return $ok
}

function Select-Cibles {
    param($Liste)
    if ($Perimetre) { return @($Liste | Where-Object { $_.nom -eq $Perimetre }) }
    return @($Liste)
}

function Remove-VieuxFichiers {
    param([string]$Dossier, [int]$Jours, [string]$Filtre = '*')
    if (-not (Test-Path $Dossier)) { return }
    $limite = (Get-Date).AddDays(-$Jours)
    Get-ChildItem $Dossier -Filter $Filtre -Force | Where-Object { $_.LastWriteTime -lt $limite } | ForEach-Object {
        if ($DryRun) { Write-Host "  (simulation) suppression $($_.FullName)" }
        else { Remove-Item $_.FullName -Recurse -Force }
    }
}

# ---------------------------------------------------------------- actions

function Invoke-Sync {
    if (-not (Test-Prerequis -Syncs)) { $script:Echecs++; return }
    foreach ($s in (Select-Cibles $Config.syncs)) {
        $t0 = Get-Date
        $log = Join-Path $Config.logDir ("sync-{0}-{1}.log" -f $s.nom, $script:Horodatage)
        # --backup-dir : ce que rclone supprimerait ou écraserait sur le disque est déplacé dans la corbeille datée.
        # C'est ce qui protège d'un ransomware ou d'une suppression massive côté OneDrive.
        $corbeille = Join-Path $Config.corbeille ("{0}\{1}" -f $s.nom, $script:Horodatage)
        $code = Invoke-Rclone -LogFile $log -Arguments @(
            'sync', $s.remote, $s.dest,
            '--backup-dir', $corbeille,
            '--exclude', '~$*', '--exclude', '*.tmp', '--exclude', 'desktop.ini',
            '--onedrive-delta',
            '--retries', '3', '--low-level-retries', '10',
            '--transfers', '8', '--checkers', '16'
        )
        $duree = ((Get-Date) - $t0).TotalSeconds
        if ($code -ne 0) { Write-Journal 'Sync' $s.nom "ECHEC(rc=$code)" $duree "voir $log" }
        elseif ($DryRun) { Write-Journal 'Sync' $s.nom 'SIMULATION' $duree $log }
        else { Write-Journal 'Sync' $s.nom 'OK' $duree $log }
    }
    # Ménage : corbeilles et logs anciens
    Remove-VieuxFichiers $Config.corbeille $Config.corbeilleRetentionDays
    Remove-VieuxFichiers $Config.logDir $Config.logRetentionDays '*.log'
}

function Invoke-Archive {
    if (-not (Test-Prerequis -Archives)) { $script:Echecs++; return }
    $anneeLimite = (Get-Date).Year - $Config.ageArchivageAnnees
    $zipTool = if (Test-Path $Config.sevenZip) { '7z' } else { 'Compress-Archive' }
    if ($zipTool -eq 'Compress-Archive') {
        Write-Host "AVERTISSEMENT : 7-Zip absent, Compress-Archive sera utilisé (limite 2 Go par archive, plus lent)." -ForegroundColor Yellow
    }

    foreach ($a in (Select-Cibles $Config.archives)) {
        $dossiers = @(Get-ChildItem $a.staging -Directory -ErrorAction SilentlyContinue)
        if ($dossiers.Count -eq 0) {
            Write-Host "Archive $($a.nom) : rien dans $($a.staging), on passe." -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path $a.zipDir)) { New-Item -ItemType Directory -Path $a.zipDir -Force | Out-Null }

        # 1. Garde-fou : un dossier trop récent (préfixe AAMM) ne doit pas partir en Glacier
        foreach ($d in $dossiers) {
            if ($d.Name -match '^(\d{2})(\d{2})') {
                $annee = 2000 + [int]$Matches[1]
                if ($annee -gt $anneeLimite) {
                    Write-Host "AVERTISSEMENT : $($d.Name) date de $annee (> $anneeLimite), vérifier qu'il doit vraiment être archivé." -ForegroundColor Yellow
                }
            }
        }

        # 2. Compression, un zip par dossier de projet, sans écraser un zip existant
        foreach ($d in $dossiers) {
            $t0 = Get-Date
            $zip = Join-Path $a.zipDir ($d.Name + '.zip')
            if (Test-Path $zip) { Write-Host "  $($d.Name).zip existe déjà, conservé."; continue }
            if ($DryRun) { Write-Journal 'Zip' $d.Name 'SIMULATION' 0; continue }
            try {
                if ($zipTool -eq '7z') {
                    & $Config.sevenZip a -tzip -mx=1 -bso0 -bsp0 "$zip" "$($d.FullName)\*" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "7z rc=$LASTEXITCODE" }
                } else {
                    Compress-Archive -Path $d.FullName -DestinationPath $zip -CompressionLevel Fastest
                }
                Write-Journal 'Zip' $d.Name 'OK' ((Get-Date) - $t0).TotalSeconds ("{0:N0} Mo" -f ((Get-Item $zip).Length / 1MB))
            } catch {
                Write-Journal 'Zip' $d.Name 'ECHEC' ((Get-Date) - $t0).TotalSeconds $_.Exception.Message
            }
        }

        # 3. Envoi vers Scaleway Glacier (copy = n'efface jamais rien côté bucket)
        $t0 = Get-Date
        $log = Join-Path $Config.logDir ("archive-{0}-{1}.log" -f $a.nom, $script:Horodatage)
        $code = Invoke-Rclone -LogFile $log -Arguments @(
            'copy', $a.zipDir, $a.bucket,
            '--s3-storage-class', 'GLACIER',
            '--s3-upload-concurrency', '4', '--s3-chunk-size', '64M',
            '--retries', '3', '--low-level-retries', '10'
        )
        $duree = ((Get-Date) - $t0).TotalSeconds
        if ($code -ne 0) { Write-Journal 'Upload' $a.nom "ECHEC(rc=$code)" $duree "voir $log"; continue }
        if ($DryRun) { Write-Journal 'Upload' $a.nom 'SIMULATION' $duree $log; continue }

        # 4. Vérification indépendante : chaque zip local doit exister dans le bucket avec la même taille/empreinte
        $t0 = Get-Date
        $logCheck = Join-Path $Config.logDir ("check-{0}-{1}.log" -f $a.nom, $script:Horodatage)
        $code = Invoke-Rclone -LogFile $logCheck -Arguments @('check', $a.zipDir, $a.bucket, '--one-way')
        $duree = ((Get-Date) - $t0).TotalSeconds
        if ($code -ne 0) { Write-Journal 'Verif' $a.nom "ECHEC(rc=$code)" $duree "NE PAS supprimer les zips, voir $logCheck"; continue }
        Write-Journal 'Verif' $a.nom 'OK' $duree "$($dossiers.Count) dossier(s) présents dans $($a.bucket)"

        # 5. Rangement local : les dossiers sources rejoignent l'archive locale, les zips sont supprimés
        if (-not (Test-Path $a.destinationLocale)) { New-Item -ItemType Directory -Path $a.destinationLocale -Force | Out-Null }
        foreach ($d in $dossiers) {
            $cible = Join-Path $a.destinationLocale $d.Name
            if (Test-Path $cible) { Write-Host "  $cible existe déjà, dossier laissé dans le staging." -ForegroundColor Yellow; continue }
            Move-Item $d.FullName $cible
        }
        Get-ChildItem $a.zipDir -Filter '*.zip' | Remove-Item -Force
        Write-Journal 'Archive' $a.nom 'OK' 0 "$($dossiers.Count) dossier(s) déplacés vers $($a.destinationLocale)"
    }
}

function Invoke-Check {
    Write-Host "== Prérequis ==" -ForegroundColor Cyan
    $ok = Test-Prerequis -Syncs -Archives
    Write-Host ("  rclone : " + (& $Config.rclone version | Select-Object -First 1))
    Write-Host ("  7-Zip  : " + $(if (Test-Path $Config.sevenZip) { 'présent' } else { 'ABSENT (recommandé)' }))

    Write-Host "== Dernières exécutions (journal) ==" -ForegroundColor Cyan
    if (Test-Path $Config.journal) {
        $j = Import-Csv $Config.journal
        foreach ($act in 'Sync', 'Archive') {
            $j | Where-Object { $_.Action -eq $act } | Group-Object Cible | ForEach-Object {
                $der = $_.Group | Select-Object -Last 1
                $age = ((Get-Date) - [datetime]$der.Date).Days
                $alerte = if ($act -eq 'Sync' -and $age -gt 40) { '  <-- plus de 40 jours !' } else { '' }
                Write-Host ("  {0,-8} {1,-18} {2}  {3,-14} il y a {4} j{5}" -f $act, $_.Name, $der.Date, $der.Resultat, $age, $alerte)
            }
        }
    } else { Write-Host "  aucun journal ($($Config.journal))" -ForegroundColor Yellow }

    Write-Host "== Buckets Scaleway ==" -ForegroundColor Cyan
    foreach ($a in $Config.archives) {
        try { Write-Host ("  {0,-40} " -f $a.bucket) -NoNewline; & $Config.rclone size $a.bucket --json | Out-String | Write-Host }
        catch { Write-Host "  inaccessible : $_" -ForegroundColor Red }
    }
    if (-not $ok) { $script:Echecs++ }
}

function Invoke-Status {
    if (-not (Test-Path $Config.journal)) { Write-Host "Aucun journal : $($Config.journal)"; return }
    Import-Csv $Config.journal | Select-Object -Last 30 | Format-Table -AutoSize
}

# ---------------------------------------------------------------- exécution

if (-not (Test-Path $ConfigPath)) { throw "Configuration introuvable : $ConfigPath" }
$Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not (Test-Path $Config.logDir)) { New-Item -ItemType Directory -Path $Config.logDir -Force -ErrorAction SilentlyContinue | Out-Null }

Write-Host ("=== Archivage RSR Conseil : {0}{1} — {2} ===" -f $Action, $(if ($DryRun) { ' (SIMULATION)' } else { '' }), (Get-Date)) -ForegroundColor Cyan

switch ($Action) {
    'Sync'    { Invoke-Sync }
    'Archive' { Invoke-Archive }
    'Check'   { Invoke-Check }
    'Status'  { Invoke-Status }
}

if ($script:Echecs -gt 0) {
    Write-Host "=== Terminé avec $($script:Echecs) échec(s) ===" -ForegroundColor Red
    exit 1
}
Write-Host "=== Terminé sans erreur ===" -ForegroundColor Green
exit 0
