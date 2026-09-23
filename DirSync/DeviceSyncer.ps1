#Requires -Version 5.1
<#
.SYNOPSIS
  DeviceSyncer (OneFile) - Sync AD Computer userCertificate -> Entra Device alternativeSecurityIds (type 2)
  with Out-GridView selection of what to sync.

.NOTES
  - PowerShell 5.1 compatible
  - Requires: ActiveDirectory module + Microsoft.Graph module + Out-GridView (Microsoft.PowerShell.GraphicalTools / RSAT)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SearchBase = "OU=TEMP,OU=Clients,OU=HomeOU,DC=home,DC=local",

    [Parameter(Mandatory=$false)]
    [string[]]$GraphScopes = @("Device.ReadWrite.All","Directory.AccessAsUser.All"),

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,

    [Parameter(Mandatory=$false)]
    [switch]$ForceRecreateOnMismatch,

    [Parameter(Mandatory=$false)]
    [string]$LogPath = "$PSScriptRoot\DeviceSyncer-OneFile.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------
# Logging
# ----------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if ($LogPath) {
        try {
            $dir = Split-Path -Parent $LogPath
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Content -Path $LogPath -Value $line -Encoding UTF8
        } catch {
            # ignore log write issues
        }
    }
}

# ----------------------------
# Helpers: Certificate selection + altSecId
# ----------------------------
function Get-DeviceJoinCertFromUserCertificate {
    param(
        [Parameter(Mandatory=$true)][object]$UserCertificateValue,
        [Parameter(Mandatory=$true)][Guid]$ObjectGuid
    )
    # userCertificate can be:
    # - $null
    # - byte[]
    # - object[] / byte[][] (multi-valued)
    if (-not $UserCertificateValue) { return $null }

    $guidText = $ObjectGuid.ToString().ToLowerInvariant()
    $candidates = @()

    foreach ($entry in @($UserCertificateValue)) {
        try {
            $bytes = [byte[]]$entry
            $cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$bytes)

            # Expect CN=<guid> (with or without braces)
            $subj = $cert.Subject
            $cn = $null
            if ($subj -match 'CN\s*=\s*([^,]+)') {
                $cn = $Matches[1].Trim()
            }
            if ($cn) {
                $cnNorm = $cn.Trim('{}').ToLowerInvariant()
                if ($cnNorm -eq $guidText) {
                    $candidates += [pscustomobject]@{
                        Bytes    = $bytes
                        NotBefore = $cert.NotBefore
                        Thumbprint = ($cert.Thumbprint -replace '\s','').ToUpperInvariant()
                        Subject  = $cert.Subject
                    }
                }
            }
        } catch {
            # ignore invalid cert entries
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    # Pick newest NotBefore
    $best = $candidates | Sort-Object NotBefore -Descending | Select-Object -First 1
    return $best
}

function Get-AltSecIdFromCertBytes {
    param(
        [Parameter(Mandatory=$true)][byte[]]$CertBytes
    )
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$CertBytes)
    $thumb = ($cert.Thumbprint -replace '\s','').ToUpperInvariant()

    # IMPORTANT: hash over cert.GetPublicKey() bytes (matches your verified yO0S... case)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $pubKeyBytes = $cert.GetPublicKey()
    $hashBytes = $sha256.ComputeHash($pubKeyBytes)
    $hashB64 = [Convert]::ToBase64String($hashBytes)

    return "X509:<SHA1-TP-PUBKEY>$thumb$hashB64"
}

function Decode-EntraAltSecId {
    param(
        [Parameter(Mandatory=$true)][object]$AlternativeSecurityIds
    )
    if (-not $AlternativeSecurityIds) { return $null }

    # pick first item with type 2 if present
    $item = $null
    foreach ($x in @($AlternativeSecurityIds)) {
        try {
            if ($null -ne $x.type -and [int]$x.type -eq 2) { $item = $x; break }
        } catch {}
        try {
            if ($null -ne $x.Type -and [int]$x.Type -eq 2) { $item = $x; break }
        } catch {}
    }
    if (-not $item) { $item = @($AlternativeSecurityIds)[0] }

    $key = $null
    try { $key = $item.key } catch {}
    if (-not $key) { try { $key = $item.Key } catch {} }

    if (-not $key) { return $null }

    try {
        if ($key -is [string]) {
            $bytes = [Convert]::FromBase64String($key)
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }
        elseif ($key -is [byte[]]) {
            return [System.Text.Encoding]::Unicode.GetString($key)
        }
    } catch {}
    return $null
}

# ----------------------------
# AD Inventory
# ----------------------------
function Get-ADComputerInventory {
    param(
        [string]$OU
    )

    Write-Host "Suche Computer unter: $OU"

    $searchRoot = [ADSI]"LDAP://$OU"
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)

    $searcher.Filter = "(objectClass=computer)"
    $searcher.SearchScope = "Subtree"
    $searcher.PageSize = 1000

    # WICHTIG: explizite Properties
    $props = @(
        "name","dnshostname","operatingsystem","operatingsystemversion",
        "objectguid","objectsid","usercertificate","whencreated","whenchanged"
    )

    foreach ($p in $props) {
        $null = $searcher.PropertiesToLoad.Add($p)
    }

    $results = $searcher.FindAll()

    $devices = @()

    foreach ($result in $results) {

        $entry = $result.Properties

        # GUID sauber lesen
        $guid = if ($entry.objectguid) {
            New-Object Guid (,$entry.objectguid[0])
        }

        # SID sauber lesen
        $sid = if ($entry.objectsid) {
            (New-Object System.Security.Principal.SecurityIdentifier($entry.objectsid[0],0)).Value
        }

        # userCertificate (multi-valued!)
        $certs = @()
        if ($entry.usercertificate) {
            foreach ($c in $entry.usercertificate) {
                $certs += ,([byte[]]$c)
            }
        }

        # passenden Join‑Cert auswählen
        $bestCert = Get-DeviceJoinCertFromUserCertificate `
            -UserCertificateValue $certs `
            -ObjectGuid $guid

        $altSecId = $null

        if ($bestCert) {
            $altSecId = Get-AltSecIdFromCertBytes -CertBytes $bestCert.Bytes
        }

        $devices += [PSCustomObject]@{
            
            DisplayName = if ($entry.dnshostname) {
                $entry.dnshostname[0].Split('.')[0]
            } else {
                $entry.name[0]
            }
            sourceAnchor = [Convert]::ToBase64String($guid.ToByteArray())
            AccountEnabled = $true
            DeviceId = $guid.ToString()
            ObjectSid = $sid

            UserCertificate = $certs
            
            JoinCertThumbprint = $bestCert.Thumbprint
            JoinCertNotBefore = $bestCert.NotBefore
            AltSecId = $altSecId

            CloudFiltered = if (-not $bestCert) { $true } else { $null }
            operatingSystemVersion = if (
                $AD.PSObject.Properties.Name -contains "OperatingSystemVersion" -and
                $AD.OperatingSystemVersion
            ) {
                $AD.OperatingSystemVersion
            } else {
                "10"
            }
            ObjectGUID = $guid
            deviceOSType = "Windows"
        }
    }

    return $devices
}

# ----------------------------
# Entra Inventory
# ----------------------------
function Connect-Graph {
    param([string[]]$Scopes)

    # Import graph module if available
    try {
        Import-Module Microsoft.Graph.authentication -ErrorAction Stop
    } catch {
        throw "Microsoft.Graph PowerShell module not found. Install-Module Microsoft.Graph"
    }

    Write-Log "Connecting to Microsoft Graph with scopes: $($Scopes -join ', ')" "INFO"
    Connect-MgGraph -Scopes $Scopes | Out-Null
}

function Get-EntraDeviceInventory {
    # ask for needed fields only
    $devices = Get-MgDevice -All -Property "id,deviceId,displayName,accountEnabled,alternativeSecurityIds,mdmAppId"
    $out = @()

    foreach ($d in $devices) {
        $alt = Decode-EntraAltSecId -AlternativeSecurityIds $d.alternativeSecurityIds
        $out += [pscustomobject]@{
            Id = $d.Id
            DeviceId = $d.DeviceId
            DisplayName = $d.DisplayName
            AccountEnabled = $d.AccountEnabled
            AlternativeSecurityIds = $d.AlternativeSecurityIds
            AltSecIdDecoded = $alt
            MdmAppId = $d.MdmAppId
        }
    }
    return $out
}

# ----------------------------
# Sync operations
# ----------------------------
function ConvertBase64ToUTF8Hex {
    param(
        [string]$Base64String
    )

    $bytes = [Convert]::FromBase64String($Base64String)
    ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function New-EntraDeviceFromAD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $AD,
        [Parameter(Mandatory=$true)] [string]$AltSecIdString
    )

    Write-Host "Creating device: $($AD.DisplayName)"
    Write-Host "AltSecId: $AltSecIdString"

    # Edm.Binary (alternativeSecurityIds.key) als Base64-String senden
    $keyBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($AltSecIdString))

    # OPTIONAL: userCertificate (byte[]) zu Base64-String machen, damit es NICHT als JSON-Array rausgeht
    # (Wenn du multi-valued hast, nimm fürs Experiment erst mal den ersten Eintrag.)
    $ucBase64 = $null
    if ($AD.PSObject.Properties.Name -contains "userCertificate" -and $AD.userCertificate) {
        # userCertificate kann byte[] oder byte[][] sein
        $first = $AD.userCertificate
        if ($first -is [System.Array] -and $first.Count -gt 0 -and $first[0] -is [byte[]]) {
            $first = $first[0]
        }
        if ($first -is [byte[]]) {
            $ucBase64 = [Convert]::ToBase64String($first)
        }
    }

    # dein DN-Spielplatz
    $dn = "CN={$($AD.DeviceId)}"

    # Body (v1.0/devices)
    $body = [ordered]@{
        accountEnabled         = [bool]$AD.AccountEnabled
        displayName            = $AD.DisplayName
        deviceId               = [string]$AD.DeviceId
        operatingSystem        = "Windows"
        operatingSystemVersion = "10"

        alternativeSecurityIds = @(
            [ordered]@{
                type = 2
                key  = $keyBase64   # <- PrimitiveValue (string), kein Array
            }
        )

        # --- "AdditionalProperties" Testfelder als Top-Level Keys (open type) [1](https://learn.microsoft.com/en-us/graph/api/resources/device?view=graph-rest-1.0)
        deviceOSType      = "Windows"
        deviceTrustType   = "ServerAd"
        distinguishedName = $dn
    }

    # userCertificate nur als Base64-STRING anhängen (sonst StartArray)
    #if ($ucBase64) {
        #$body.userCertificate = $ucBase64
    #}

    # HIER ist dein gewünschter 403-Trigger (read-only laut Schema) [1](https://learn.microsoft.com/en-us/graph/api/resources/device?view=graph-rest-1.0)
    $body.onPremisesSecurityIdentifier = $AD.ObjectSid

    $json = $body | ConvertTo-Json -Depth 20

    # optional: Payload sichtbar machen
    $json | Out-File "$env:TEMP\devcreate.json" -Encoding utf8
    Write-Host "DBG payload: $env:TEMP\devcreate.json"

    Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/devices" -Body $json -ContentType "application/json"
}

function Remove-EntraDevice {
    param([Parameter(Mandatory=$true)][string]$EntraObjectId)

    if ($WhatIf) {
        Write-Log "WHATIF: would delete Entra device objectId=$EntraObjectId" "WARN"
        return
    }

    Remove-MgDevice -DeviceId $EntraObjectId
    Write-Log "Deleted Entra device objectId=$EntraObjectId" "INFO"
}

function Update-EntraAltSecId {
    param(
        [Parameter(Mandatory=$true)][pscustomobject]$Entra,
        [Parameter(Mandatory=$true)][string]$AltSecIdString
    )

    $keyBytes = [System.Text.Encoding]::Unicode.GetBytes($AltSecIdString)
    $patch = @{
        alternativeSecurityIds = @(
            @{
                type = 2
                key  = $keyBytes
            }
        )
    }

    if ($WhatIf) {
        Write-Log "WHATIF: would update altSecId for Entra device $($Entra.DisplayName) ($($Entra.DeviceId))" "WARN"
        return
    }

    Update-MgDevice -DeviceId $Entra.Id -BodyParameter $patch
    Write-Log "Updated altSecId for Entra device: $($Entra.DisplayName)" "INFO"
}

# ----------------------------
# Main
# ----------------------------
Write-Log "DeviceSyncer-OneFile starting" "INFO"
Write-Log "SearchBase: $SearchBase" "INFO"

$ad = Get-ADComputerInventory -OU $SearchBase
$ad = @($ad)
Write-Log "AD computers loaded: $($ad.Count)" "INFO"

Connect-Graph -Scopes $GraphScopes
$entra = Get-EntraDeviceInventory
$entra = @($entra)
Write-Log "Entra devices loaded: $($entra.Count)" "INFO"

# Build lookup by DeviceId
$entraByDeviceId = @{}
foreach ($e in $entra) {
    if ($e.DeviceId) { $entraByDeviceId[$e.DeviceId.ToString()] = $e }
}

# Build candidates
$candidates = @()

foreach ($a in $ad) {
    $action = "SKIP"
    $reason = $null
    $match = $false
    $entraAlt = $null
    $exists = $false

    if ($a.CloudFiltered -eq $true) {
        $action = "SKIP"
        $reason = "Filtered: no suitable userCertificate join cert"
    } else {
        if ($entraByDeviceId.ContainsKey($a.DeviceId)) {
            $exists = $true
            $e = $entraByDeviceId[$a.DeviceId]
            $entraAlt = $e.AltSecIdDecoded

            if ($entraAlt -and $a.AltSecId -and ($entraAlt -eq $a.AltSecId)) {
                $action = "SKIP"
                $reason = "Exists: altSecId matches"
                $match = $true
            } else {
                if ($ForceRecreateOnMismatch) {
                    $action = "RECREATE"
                    $reason = "Mismatch: recreate requested"
                } else {
                    $action = "UPDATE"
                    $reason = "Mismatch: update altSecId"
                }
            }
        } else {
            $action = "CREATE"
            $reason = "Missing in Entra"
        }
    }

    $candidates += [pscustomobject]@{
        Action = $action
        Reason = $reason
        DisplayName = $a.DisplayName
        DeviceId = $a.DeviceId
        JoinCertThumbprint = $a.JoinCertThumbprint
        JoinCertNotBefore = $a.JoinCertNotBefore
        AD_AltSecId = $a.AltSecId
        Entra_AltSecId = $entraAlt
        InEntra = $exists
    }
}

# Show Out-GridView for actionable items
$pick = $candidates |
    Where-Object { $_.Action -in @("CREATE","UPDATE","RECREATE") } |
    Sort-Object Action, DisplayName |
    Out-GridView -Title "Select devices to sync (CREATE/UPDATE/RECREATE)" -PassThru

$pick = @($pick)
if (-not $pick -or $pick.Count -eq 0) {
    Write-Log "No items selected. Exiting." "WARN"
    return
}

Write-Log "Selected: $($pick.Count) items" "INFO"

foreach ($row in $pick) {
    $deviceId = $row.DeviceId
    $adObj = $ad | Where-Object { $_.DeviceId -eq $deviceId } | Select-Object -First 1
    if (-not $adObj) {
        Write-Log "AD object not found for DeviceId $deviceId - skipping" "ERROR"
        continue
    }
    if (-not $adObj.AltSecId) {
        Write-Log "No AltSecId for $($adObj.DisplayName) - skipping" "ERROR"
        continue
    }

    if ($row.Action -eq "CREATE") {
        Write-Log "CREATE: $($adObj.DisplayName)" "INFO"
        New-EntraDeviceFromAD -AD $adObj -AltSecIdString $adObj.AltSecId
    }
    elseif ($row.Action -eq "UPDATE") {
        Write-Log "UPDATE: $($adObj.DisplayName)" "INFO"
        $e = $entraByDeviceId[$deviceId]
        if (-not $e) {
            Write-Log "Entra object missing for UPDATE DeviceId $deviceId - skipping" "ERROR"
            continue
        }
        Update-EntraAltSecId -Entra $e -AltSecIdString $adObj.AltSecId
    }
    elseif ($row.Action -eq "RECREATE") {
        Write-Log "RECREATE: $($adObj.DisplayName)" "INFO"
        $e = $entraByDeviceId[$deviceId]
        if ($e) {
            Remove-EntraDevice -EntraObjectId $e.Id
        }
        New-EntraDeviceFromAD -AD $adObj -AltSecIdString $adObj.AltSecId
    }
}

Write-Log "DeviceSyncer-OneFile finished" "INFO"