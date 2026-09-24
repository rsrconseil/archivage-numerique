<#
.SYNOPSIS
    Empêche la mise en veille du PC tant qu'une copie nas-pull est en cours (verrou présent).

.DESCRIPTION
    Utilise la même demande système qu'un lecteur vidéo (SetThreadExecutionState) : aucun réglage
    Windows n'est modifié, et la demande disparaît dès que ce script se termine. Le script se termine
    de lui-même quand le verrou de nas-pull disparaît, ou après -MaxHeures.
    N'empêche pas la veille si le couvercle est fermé ou si la veille est demandée à la main.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Garder-Eveille.ps1
#>
param([int]$MaxHeures = 14)
$verrou = Join-Path $env:LOCALAPPDATA 'RSR-Archivage\logs\nas-pull.lock'
Add-Type -Namespace RSR -Name Veille -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
$ES_CONTINUOUS = [uint32]2147483648; $ES_SYSTEM_REQUIRED = [uint32]1   # 0x80000000 et 0x00000001
$fin = (Get-Date).AddHours($MaxHeures)
Write-Host "Gardien de veille actif tant que $verrou existe (au plus jusqu'à $fin)."
try {
    while ((Test-Path $verrou) -and (Get-Date) -lt $fin) {
        [RSR.Veille]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
        Start-Sleep -Seconds 60
    }
} finally {
    [RSR.Veille]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Write-Host "Gardien de veille terminé : $(Get-Date)"
}
