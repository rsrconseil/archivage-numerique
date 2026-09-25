<#
.SYNOPSIS
    Copie de secours des buckets Scaleway vers le NAS UniFi (voie A).

.DESCRIPTION
    Tourne sur le PC de Raphaël, lancé chaque jour par une tâche planifiée. Il ne fait
    quelque chose que si la dernière copie réussie date de plus de 'frequenceJours'
    (7 par défaut) ET que le NAS est joignable. Sinon il se termine en quelques secondes.

    Pour chaque entrée 'copies' du fichier nas-pull.json :
      rclone sync <bucket> -> <partage NAS>, avec corbeille datée sur le NAS (z-corbeille\<date>)
      pour tout fichier supprimé ou écrasé, purgée après 'corbeilleRetentionDays'.
    La corbeille du bucket (_corbeille/) n'est pas recopiée : le NAS a ses propres instantanés.

    Actions :
      Sync    copie (ne fait rien si la dernière réussite est récente, sauf -Force)
      Check   contrôle sans rien écrire : rclone, remote, NAS, partages, dernières copies
      Status  dernières lignes du journal

    Code de sortie : 0 OK ou rien à faire, 1 échec de copie, 3 NAS injoignable, 2 prérequis.

.EXAMPLE
    .\NasPull.ps1 -Action Check
    .\NasPull.ps1 -Action Sync -DryRun -Force
    .\NasPull.ps1 -Action Sync -Perimetre miroir -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Sync', 'Check', 'Status')] [string]$Action,
    [string]$Perimetre,
    [switch]$DryRun,
    [switch]$Force,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'nas-pull.json' }
if (-not (Test-Path $ConfigPath)) { throw "Configuration introuvable : $ConfigPath" }
$Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$LogDir  = [Environment]::ExpandEnvironmentVariables($Config.logDir)
$Journal = [Environment]::ExpandEnvironmentVariables($Config.journal)
$Horodatage = Get-Date -Format 'yyyyMMdd-HHmm'
$script:Echecs = 0
foreach ($d in @($LogDir, (Split-Path $Journal))) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# ---------------------------------------------------------------- utilitaires

function Write-Journal {
    param([string]$Cible, [string]$Resultat, [double]$Secondes = 0, [string]$Detail = '')
    $ligne = [pscustomobject]@{
        Date = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Machine = $env:COMPUTERNAME; Cible = $Cible
        Resultat = $Resultat; Secondes = [math]::Round($Secondes); Detail = $Detail
    }
    $ligne | Export-Csv -Path $Journal -Append:(Test-Path $Journal) -NoTypeInformation -Encoding UTF8
    $c = switch -Wildcard ($Resultat) { 'OK' { 'Green' } 'SIMULATION' { 'Cyan' } 'RIEN*' { 'Gray' } default { 'Red' } }
    Write-Host ("[{0}] {1,-10} {2,-14} {3}s {4}" -f $ligne.Date, $Cible, $Resultat, $ligne.Secondes, $Detail) -ForegroundColor $c
    if ($Resultat -like 'ECHEC*') { $script:Echecs++ }
}

function Select-Copies { if ($Perimetre) { @($Config.copies | Where-Object { $_.nom -eq $Perimetre }) } else { @($Config.copies) } }

function Test-Nas {
    try { (Test-NetConnection $Config.nas -Port 445 -WarningAction SilentlyContinue -InformationLevel Quiet) } catch { $false }
}

function Get-DerniereReussite([string]$nom) {
    if (-not (Test-Path $Journal)) { return $null }
    $l = Import-Csv $Journal | Where-Object { $_.Cible -eq $nom -and $_.Resultat -eq 'OK' } | Select-Object -Last 1
    if ($l) { [datetime]$l.Date } else { $null }
}

function Test-Prerequis {
    $ok = $true
    if (-not (Get-Command $Config.rclone -ErrorAction SilentlyContinue)) { Write-Host "ERREUR : rclone introuvable" -ForegroundColor Red; return $false }
    $remotes = (& $Config.rclone listremotes) -split "`n" | ForEach-Object { $_.Trim() }
    if ($remotes -notcontains $Config.remote) {
        Write-Host "ERREUR : remote rclone absent : $($Config.remote). Voir INSTALLATION.md, étape 2." -ForegroundColor Red; $ok = $false
    }
    if (-not (Test-Nas)) { Write-Host "NAS $($Config.nas) injoignable (port 445)." -ForegroundColor Yellow; return $null }
    foreach ($c in (Select-Copies)) {
        if (-not (Test-Path $c.dest)) { Write-Host "ERREUR : partage inaccessible : $($c.dest)" -ForegroundColor Red; $ok = $false }
    }
    return $ok
}

function Remove-VieuxFichiers([string]$Dossier, [int]$Jours) {
    if (-not (Test-Path $Dossier)) { return }
    Get-ChildItem $Dossier -Force | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Jours) } | ForEach-Object {
        if ($DryRun) { Write-Host "  (simulation) suppression $($_.FullName)" } else { Remove-Item $_.FullName -Recurse -Force }
    }
}

# ---------------------------------------------------------------- actions

function Invoke-Sync {
    # Verrou : une seule copie à la fois (lancement manuel et tâche planifiée peuvent se croiser)
    $verrou = Join-Path $LogDir 'nas-pull.lock'
    if (Test-Path $verrou) {
        $pid0 = Get-Content $verrou -ErrorAction SilentlyContinue
        if ($pid0 -and (Get-Process -Id $pid0 -ErrorAction SilentlyContinue)) { Write-Journal 'nas' 'RIEN (copie déjà en cours)'; exit 0 }
        Remove-Item $verrou -Force -ErrorAction SilentlyContinue
    }
    $PID | Set-Content $verrou
    try {
    $pre = Test-Prerequis
    if ($null -eq $pre) { Write-Journal 'nas' 'RIEN (NAS absent)'; exit 3 }
    if (-not $pre) { exit 2 }

    foreach ($c in (Select-Copies)) {
        $der = Get-DerniereReussite $c.nom
        if (-not $Force -and $der -and ((Get-Date) - $der).TotalDays -lt $Config.frequenceJours) {
            Write-Journal $c.nom ('RIEN (copie du {0})' -f $der.ToString('dd/MM')); continue
        }
        $t0 = Get-Date
        $log = Join-Path $LogDir ("nas-pull-{0}-{1}.log" -f $c.nom, $Horodatage)
        $corbeille = Join-Path $c.dest ("z-corbeille\{0}" -f $Horodatage)
        $rcArgs = @('sync', "$($Config.remote)$($c.bucket)", $c.dest,
                  '--backup-dir', $corbeille,
                  '--fast-list', '--transfers', '8', '--checkers', '16',
                  # --ignore-errors : quelques fichiers aux noms trop longs pour le NAS échouent à chaque passage ;
                  # sans ce drapeau rclone refuserait de déplacer en corbeille ce qui a disparu du bucket. La source
                  # (S3) est listée de façon fiable, le déplacement en corbeille reste sûr, et les échecs restent journalisés.
                  '--ignore-errors',
                  '--retries', '3', '--low-level-retries', '10',
                  '--log-file', $log, '--log-level', 'INFO', '--stats', '5m', '--stats-one-line')
        foreach ($e in @($Config.exclusions) + @($c.exclusions)) { if ($e) { $rcArgs += @('--exclude', $e) } }
        if ($DryRun) { $rcArgs += '--dry-run' }
        "commande : rclone " + ($rcArgs -join ' ') | Set-Content $log -Encoding UTF8
        & $Config.rclone @rcArgs
        $code = $LASTEXITCODE
        $duree = ((Get-Date) - $t0).TotalSeconds
        if ($code -ne 0) { Write-Journal $c.nom "ECHEC(rc=$code)" $duree "voir $log" }
        elseif ($DryRun) { Write-Journal $c.nom 'SIMULATION' $duree $log }
        else { Write-Journal $c.nom 'OK' $duree $log }
        Remove-VieuxFichiers (Join-Path $c.dest 'z-corbeille') $Config.corbeilleRetentionDays
    }
    Remove-VieuxFichiers $LogDir $Config.logRetentionDays
    } finally { Remove-Item $verrou -Force -ErrorAction SilentlyContinue }
}

function Invoke-Check {
    Write-Host "== Prérequis ==" -ForegroundColor Cyan
    $pre = Test-Prerequis
    Write-Host ("  rclone : " + (& $Config.rclone version | Select-Object -First 1))
    Write-Host ("  NAS    : " + $(if ($null -eq $pre) { 'injoignable' } else { 'joignable' }))
    if ($pre) {
        Write-Host "== Buckets (lecture) ==" -ForegroundColor Cyan
        foreach ($c in (Select-Copies)) {
            $r = & $Config.rclone size "$($Config.remote)$($c.bucket)" --json --exclude '_corbeille/**' 2>&1
            Write-Host ("  {0,-10} {1,-14} {2}" -f $c.nom, $c.bucket, ($r | Out-String).Trim())
        }
    }
    Write-Host "== Dernières copies ==" -ForegroundColor Cyan
    foreach ($c in (Select-Copies)) {
        $der = Get-DerniereReussite $c.nom
        if ($der) {
            $age = [math]::Round(((Get-Date) - $der).TotalDays)
            $alerte = if ($age -gt 2 * $Config.frequenceJours) { '  <-- en retard' } else { '' }
            Write-Host ("  {0,-10} {1}  il y a {2} j{3}" -f $c.nom, $der.ToString('yyyy-MM-dd HH:mm'), $age, $alerte)
        } else { Write-Host ("  {0,-10} jamais" -f $c.nom) -ForegroundColor Yellow }
    }
    if ($pre -eq $false) { $script:Echecs++ }
}

function Invoke-Status {
    if (-not (Test-Path $Journal)) { Write-Host "Aucun journal : $Journal"; return }
    Import-Csv $Journal | Select-Object -Last 30 | Format-Table -AutoSize
}

# ---------------------------------------------------------------- exécution

Write-Host ("=== nas-pull : {0}{1} — {2} ===" -f $Action, $(if ($DryRun) { ' (SIMULATION)' } else { '' }), (Get-Date)) -ForegroundColor Cyan
switch ($Action) { 'Sync' { Invoke-Sync } 'Check' { Invoke-Check } 'Status' { Invoke-Status } }
if ($script:Echecs -gt 0) { Write-Host "=== Terminé avec $($script:Echecs) échec(s) ===" -ForegroundColor Red; exit 1 }
Write-Host "=== Terminé ===" -ForegroundColor Green
exit 0
