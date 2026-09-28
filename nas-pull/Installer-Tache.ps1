<#
.SYNOPSIS
    Installe nas-pull dans un dossier local hors OneDrive (C:\RSR\Archivage\nas-pull) et crée
    (ou remplace) la tâche planifiée « RSR - Archivage - Copie NAS ».

.DESCRIPTION
    Pourquoi une copie locale : le 26/09/2026, la tâche planifiée et le script NasPull.ps1 (dans OneDrive)
    ont disparu deux minutes après un démarrage de la tâche, sans intervention humaine. Deux suspects :
    OneDrive (fichier synchronisé) et la protection Windows (script PowerShell caché lancé par une tâche).
    Cette version lance la tâche depuis un dossier local, avec une fenêtre réduite plutôt que cachée,
    et sous une description explicite.

    Déclenchement : chaque jour à 10 h, plus à chaque ouverture de session (5 min de délai). Le script
    NasPull.ps1 décide seul : il ne copie que si la dernière réussite date de plus de 7 jours et si le NAS
    répond. Aucun mot de passe demandé : la tâche tourne dans la session ouverte de l'utilisateur.

    Relancer ce script après toute modification des fichiers de nas-pull dans le dépôt : il recopie
    les fichiers vers C:\RSR\Archivage\nas-pull.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Installer-Tache.ps1
#>
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$cible  = 'C:\RSR\Archivage\nas-pull'

# 1. Copie locale des fichiers d'exécution (pas la doc, pas l'amorçage à usage unique)
if (-not (Test-Path $cible)) { New-Item -ItemType Directory -Path $cible -Force | Out-Null }
foreach ($f in 'NasPull.ps1', 'nas-pull.json', 'Garder-Eveille.ps1', 'Installer-Tache.ps1') {
    Copy-Item (Join-Path $source $f) (Join-Path $cible $f) -Force
}
Set-Content (Join-Path $cible 'ORIGINE.txt') "Copie installée le $(Get-Date -Format 'dd/MM/yyyy HH:mm') depuis $source`nNe pas modifier ici : modifier dans le dépôt puis relancer Installer-Tache.ps1."
$script = Join-Path $cible 'NasPull.ps1'
Write-Host "Fichiers copiés dans $cible" -ForegroundColor Green

# 2. Tâche planifiée
$nom = 'RSR - Archivage - Copie NAS'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $cible `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Minimized -ExecutionPolicy Bypass -File "{0}" -Action Sync' -f $script)
$triggers = @(
    (New-ScheduledTaskTrigger -Daily -At 10:00),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$triggers[1].Delay = 'PT5M'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Unregister-ScheduledTask -TaskName $nom -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $nom -Action $action -Trigger $triggers -Settings $settings `
    -Description "RSR Conseil, sauvegarde : copie hebdomadaire des buckets Scaleway vers le NAS UniFi (rclone, lecture seule côté cloud). Script : $script. Voir le dépôt rsrconseil/archivage-numerique." | Out-Null

Write-Host "Tâche « $nom » installée." -ForegroundColor Green
Get-ScheduledTask -TaskName $nom | Select-Object TaskName, State | Format-Table -AutoSize
Write-Host "Lancer maintenant :  Start-ScheduledTask -TaskName '$nom'"
Write-Host "Voir le résultat  :  powershell -File `"$script`" -Action Status"
