<#
.SYNOPSIS
    Renseigne les drive_id de bibliotheques.json en interrogeant Microsoft Graph
    avec les identifiants de l'application Entra ID (flux client credentials).

.DESCRIPTION
    Prérequis : une inscription d'application Entra ID avec les permissions
    d'application Sites.Read.All et Files.Read.All, consentement administrateur accordé.

    Le script ne modifie rien côté Microsoft : lecture seule.
    Il réécrit bibliotheques.json avec les drive_id trouvés et affiche un tableau.

.EXAMPLE
    .\Get-DriveIds.ps1 -TenantId <guid> -ClientId <guid>
    (le secret est demandé de façon masquée)
#>
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$ClientId,
    [string]$ConfigPath,
    # Liste les sites que Microsoft Graph renvoie à l'application, par les deux méthodes (getAllSites et search), sans rien d'autre
    [switch]$ListerSites
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) {
    $ici = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ConfigPath = Join-Path $ici 'bibliotheques.json'
}
if (-not (Test-Path $ConfigPath)) { throw "Fichier introuvable : $ConfigPath" }

$secret = Read-Host -Prompt 'Secret de l''application (saisie masquée)' -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))

# 1. Jeton d'application
$tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
    client_id = $ClientId; client_secret = $plain; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
}
$h = @{ Authorization = "Bearer $($tok.access_token)" }
$plain = $null

# Diagnostic : que contient le jeton ? (audience et rôles d'application)
$payload = ($tok.access_token -split '\.')[1].Replace('-', '+').Replace('_', '/')
switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
Write-Host ("Jeton obtenu. Audience : {0}. Rôles d'application : {1}" -f $claims.aud, $(if ($claims.roles) { $claims.roles -join ', ' } else { 'AUCUN' })) -ForegroundColor Cyan
if (-not $claims.roles) {
    Write-Host "Le jeton ne contient aucun rôle : les permissions Sites.Read.All et Files.Read.All ne sont pas accordées." -ForegroundColor Red
    Write-Host "Dans Entra > l'application > Autorisations d'API : vérifier qu'elles sont de type 'Application' (pas 'Déléguée')" -ForegroundColor Red
    Write-Host "et que la colonne Statut affiche 'Accordé pour <organisation>' (bouton 'Accorder le consentement administrateur')." -ForegroundColor Red
    exit 1
}

function Get-SiteDrives([string]$siteUrl) {
    $u = [uri]$siteUrl
    $path = $u.AbsolutePath.TrimEnd('/')
    $siteRef = if ($path -eq '' -or $path -eq '/') { $u.Host } else { "$($u.Host):$path" }
    $site = Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/sites/$siteRef"
    (Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives").value
}

if ($ListerSites) {
    function Get-Pages([string]$url) {
        $out = @()
        while ($url) { $r = Invoke-RestMethod -Headers $h -Uri $url; $out += $r.value; $url = $r.'@odata.nextLink' }
        return $out
    }
    $a = Get-Pages 'https://graph.microsoft.com/v1.0/sites/getAllSites?$select=id,displayName,webUrl'
    $b = Get-Pages 'https://graph.microsoft.com/v1.0/sites?search=*&$select=id,displayName,webUrl'
    $ua = @{}; foreach ($x in $a) { $ua[$x.webUrl] = $x }
    $ub = @{}; foreach ($x in $b) { $ub[$x.webUrl] = $x }
    $tous = @($ua.Keys + $ub.Keys | Sort-Object -Unique)
    Write-Host ("getAllSites : {0} sites, search : {1} sites, union : {2}" -f $ua.Count, $ub.Count, $tous.Count) -ForegroundColor Cyan
    $tous | ForEach-Object {
        $x = if ($ua[$_]) { $ua[$_] } else { $ub[$_] }
        [pscustomobject]@{ getAllSites = $(if ($ua[$_]) { 'oui' } else { 'NON' }); search = $(if ($ub[$_]) { 'oui' } else { 'NON' }); Nom = $x.displayName; Url = $x.webUrl }
    } | Where-Object { $_.Url -notlike '*-my.sharepoint.com*' } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $attendus = 'https://rsrci.sharepoint.com', 'https://rsrci.sharepoint.com/sites/Projetsencours', 'https://rsrci.sharepoint.com/sites/Vieducabinet', 'https://rsrci.sharepoint.com/sites/equipe'
    foreach ($u in $attendus) {
        Write-Host ("  {0,-55} getAllSites={1} search={2}" -f $u, $(if ($ua[$u]) { 'oui' } else { 'NON' }), $(if ($ub[$u]) { 'oui' } else { 'NON' })) -ForegroundColor $(if ($ua[$u]) { 'Green' } else { 'Red' })
    }
    exit 0
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$rapport = @()

foreach ($b in $cfg.bibliotheques) {
    try {
        $drives = Get-SiteDrives $b.site
        $d = $drives | Where-Object { $_.name -eq $b.bibliotheque } | Select-Object -First 1
        if (-not $d) { $d = $drives | Where-Object { $_.driveType -eq 'documentLibrary' } | Select-Object -First 1 }
        if ($d) { $b.drive_id = $d.id }
        $rapport += [pscustomobject]@{ Nom = $b.nom; Bibliotheque = $d.name; DriveId = $d.id; Statut = $(if ($d) { 'OK' } else { 'INTROUVABLE' }) }
    } catch {
        $rapport += [pscustomobject]@{ Nom = $b.nom; Bibliotheque = ''; DriveId = ''; Statut = "ERREUR : $($_.Exception.Message)" }
    }
}

try {
    $pd = Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/users/$($cfg.perso.utilisateur)/drive"
    $cfg.perso.drive_id = $pd.id
    $rapport += [pscustomobject]@{ Nom = $cfg.perso.nom; Bibliotheque = 'OneDrive'; DriveId = $pd.id; Statut = 'OK' }
} catch {
    $rapport += [pscustomobject]@{ Nom = $cfg.perso.nom; Bibliotheque = 'OneDrive'; DriveId = ''; Statut = "ERREUR : $($_.Exception.Message)" }
}

$rapport | Format-Table -AutoSize

# Vérification : les premiers dossiers à la racine de chaque lecteur, pour confirmer qu'on vise la bonne bibliothèque
Write-Host "Contenu à la racine de chaque lecteur (5 premiers éléments) :" -ForegroundColor Cyan
foreach ($b in @($cfg.bibliotheques) + @($cfg.perso)) {
    if (-not $b.drive_id) { continue }
    try {
        $items = (Invoke-RestMethod -Headers $h -Uri "https://graph.microsoft.com/v1.0/drives/$($b.drive_id)/root/children?`$top=5&`$select=name").value
        Write-Host ("  {0,-16} {1}" -f $b.nom, (($items | ForEach-Object { $_.name }) -join ' | '))
    } catch { Write-Host ("  {0,-16} ERREUR : {1}" -f $b.nom, $_.Exception.Message) -ForegroundColor Red }
}
$cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
Write-Host "bibliotheques.json mis à jour. Reporter les drive_id dans rclone.conf (voir rclone.conf.template)."
