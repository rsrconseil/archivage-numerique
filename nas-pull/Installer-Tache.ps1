<#
.SYNOPSIS
    Crée (ou remplace) la tâche planifiée « RSR - Archivage - Copie NAS » sur ce PC.

.DESCRIPTION
    Déclenchement : chaque jour à 10 h, plus à chaque ouverture de session (avec 5 min de délai).
    Le script NasPull.ps1 décide lui-même s'il y a quelque chose à faire : il ne copie que si la
    dernière réussite date de plus de 7 jours et si le NAS répond. Les autres jours, il se
    termine en quelques secondes. Aucun mot de passe n'est demandé : la tâche tourne dans la
    session ouverte de l'utilisateur, ce qui suffit pour un PC portable.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Installer-Tache.ps1
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'NasPull.ps1'
if (-not (Test-Path $script)) { throw "NasPull.ps1 introuvable à côté de ce fichier" }

$nom = 'RSR - Archivage - Copie NAS'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Sync' -f $script)
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
    -Description 'Copie hebdomadaire des buckets Scaleway vers le NAS UniFi, quand le NAS est joignable.' | Out-Null

Write-Host "Tâche « $nom » installée." -ForegroundColor Green
Get-ScheduledTask -TaskName $nom | Select-Object TaskName, State | Format-Table -AutoSize
Write-Host "Lancer maintenant :  Start-ScheduledTask -TaskName '$nom'"
Write-Host "Voir le résultat  :  powershell -File `"$script`" -Action Status"
