<#
Baut einen Azure Communication Services (ACS) Communication Service + Email Service + Custom Domain
komplett neu auf und richtet SMTP-Relay-Authentifizierung (Entra App) dafür ein.
Siehe ACS-Email-SMTP-Relay-Setup.md fuer Hintergrund/Stolperfallen zu diesem Skript.

Voraussetzungen:
- az CLI installiert und eingeloggt (az login --tenant <TenantId>), richtige Subscription aktiv (az account set)
- 'communication' CLI-Extension wird automatisch nachinstalliert
- Eine bestehende Entra-App-Registrierung mit Client Secret (fuer SMTP AUTH). Falls noch keine existiert: -CreateEntraApp verwenden.
- Falls -UseAzureDns verwendet wird: die DNS-Zone der Domain muss bereits als Azure-DNS-Zone existieren

Beispiel (Testtenant, wie beim ersten Aufbau verwendet):
  .\New-AcsEmailRelay.ps1 -ResourceGroupName rg-comsvc-edge -CommServiceName comsvc-edge `
      -EmailServiceName acs-email-edge -DomainName example.com `
      -EntraApplicationId <AppId> -EntraTenantId <TenantId> `
      -SmtpLoginUsername edge-relay-svc -UseAzureDns -DnsZoneResourceGroup DNS

Beispiel bei einem Kunden, inkl. neuer Entra App:
  .\New-AcsEmailRelay.ps1 -ResourceGroupName rg-mail-kunde -CommServiceName comsvc-kunde `
      -EmailServiceName acs-email-kunde -DomainName mail.kunde.de `
      -CreateEntraApp -EntraAppDisplayName "ACS SMTP Relay - Kunde" `
      -SmtpLoginUsername kunde-relay-svc
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ===================== ANPASSEN =====================
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$CommServiceName,
    [Parameter(Mandatory)] [string]$EmailServiceName,
    [Parameter(Mandatory)] [string]$DomainName,

    [string]$Location = "global",
    [string]$DataLocation = "Europe",

    # Absenderadresse unter $DomainName (Default: DoNotReply@$DomainName)
    [string]$SenderUsername = "DoNotReply",
    [string]$SenderDisplayName = "DoNotReply",

    # SMTP-Login-Username: frei waehlbarer String (KEINE GUIDs/Punkt-Notation - wird von Azure abgelehnt),
    # darf nicht == Ressourcenname der SmtpUsername-Ressource und nicht == einem bestehenden SenderUsername sein.
    [Parameter(Mandatory)] [string]$SmtpLoginUsername,
    [string]$SmtpUsernameResourceName = "$CommServiceName-smtp",

    # RBAC-Rolle fuer die Entra-App auf der CommunicationService-Ressource.
    # Eingebaute Rolle verwenden (nicht subscription-gebundene Custom Role -> siehe Doku Punkt 5)
    [string]$RoleName = "Communication and Email Service Owner",

    # Bestehende Entra-App-Registrierung (Tenant-weit, unabhaengig von der Subscription)
    [string]$EntraApplicationId,
    [string]$EntraTenantId,

    # ODER: neue Entra-App anlegen lassen
    [switch]$CreateEntraApp,
    [string]$EntraAppDisplayName = "ACS SMTP Relay - $CommServiceName",

    # Optional: DNS-Records automatisch in einer Azure-DNS-Zone anlegen + Verifizierung anstossen.
    # Ohne diesen Switch: Skript zeigt die noetigen Records an und bricht vor der Verifizierung ab,
    # damit sie manuell/bei einem fremden DNS-Provider eingetragen werden koennen.
    [switch]$UseAzureDns,
    [string]$DnsZoneResourceGroup,
    [string]$DnsZoneName = $DomainName,

    [string]$SubscriptionId
    # ===================== ENDE ANPASSEN =====================
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    param([string[]]$Args)
    Write-Verbose "az $($Args -join ' ')"
    $result = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Args -join ' ') fehlgeschlagen:`n$result" }
    if ($result) { return $result | ConvertFrom-Json }
}

if ($SubscriptionId) {
    Invoke-Az @("account", "set", "--subscription", $SubscriptionId) | Out-Null
}

Invoke-Az @("extension", "add", "--name", "communication", "--upgrade") | Out-Null

# ---- Entra App ----
if ($CreateEntraApp) {
    Write-Host "Lege neue Entra-App-Registrierung an: $EntraAppDisplayName"
    $app = Invoke-Az @("ad", "app", "create", "--display-name", $EntraAppDisplayName)
    $EntraApplicationId = $app.appId
    $cred = Invoke-Az @("ad", "app", "credential", "reset", "--id", $EntraApplicationId, "--display-name", "acs-smtp-relay")
    $EntraTenantId = (Invoke-Az @("account", "show")).tenantId
    Write-Host "App-ID: $EntraApplicationId"
    Write-Warning "CLIENT SECRET (nur jetzt sichtbar, sicher speichern!): $($cred.password)"
}
elseif (-not $EntraApplicationId -or -not $EntraTenantId) {
    throw "Entweder -CreateEntraApp verwenden, oder -EntraApplicationId und -EntraTenantId einer bestehenden App angeben."
}

# ---- Resource Group ----
if (-not (Invoke-Az @("group", "exists", "--name", $ResourceGroupName))) {
    Write-Host "Lege Resource Group an: $ResourceGroupName"
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create Resource Group")) {
        Invoke-Az @("group", "create", "--name", $ResourceGroupName, "--location", "westeurope") | Out-Null
    }
}

# ---- Communication Service ----
Write-Host "Lege Communication Service an: $CommServiceName"
if ($PSCmdlet.ShouldProcess($CommServiceName, "Create Communication Service")) {
    Invoke-Az @("communication", "create", "--name", $CommServiceName, "--resource-group", $ResourceGroupName, "--location", $Location, "--data-location", $DataLocation) | Out-Null
}

# ---- Email Service + Domain ----
Write-Host "Lege Email Service an: $EmailServiceName"
if ($PSCmdlet.ShouldProcess($EmailServiceName, "Create Email Service")) {
    Invoke-Az @("communication", "email", "create", "--name", $EmailServiceName, "--resource-group", $ResourceGroupName, "--location", $Location, "--data-location", $DataLocation) | Out-Null
}

Write-Host "Lege Custom Domain an: $DomainName"
$domain = $null
if ($PSCmdlet.ShouldProcess($DomainName, "Create Custom Domain")) {
    $domain = Invoke-Az @("communication", "email", "domain", "create", "--domain-name", $DomainName, "--email-service-name", $EmailServiceName, "-g", $ResourceGroupName, "--location", $Location, "--domain-management", "CustomerManaged")
}

if (-not $domain) {
    Write-Host "WhatIf-Modus: DNS-Records koennen nicht angezeigt werden, hier abgebrochen."
    return
}

$records = $domain.verificationRecords
Write-Host "`nBenoetigte DNS-Records fuer $DomainName :"
Write-Host "  TXT  @  -> $($records.Domain.value)"
Write-Host "  TXT  @  -> $($records.SPF.value)   (NUR falls noch kein v=spf1-Record existiert - siehe Doku!)"
Write-Host "  CNAME $($records.DKIM.name)  -> $($records.DKIM.value)"
Write-Host "  CNAME $($records.DKIM2.name) -> $($records.DKIM2.value)"

# ---- DNS-Records (nur wenn -UseAzureDns) ----
if ($UseAzureDns) {
    if (-not $DnsZoneResourceGroup) { throw "-DnsZoneResourceGroup wird mit -UseAzureDns benoetigt." }

    Write-Host "`nLege DNS-Records in Azure-DNS-Zone $DnsZoneName (RG $DnsZoneResourceGroup) an..."
    if ($PSCmdlet.ShouldProcess($DnsZoneName, "Add TXT domain-verification record")) {
        Invoke-Az @("network", "dns", "record-set", "txt", "add-record", "-g", $DnsZoneResourceGroup, "-z", $DnsZoneName, "-n", "@", "-v", $records.Domain.value) | Out-Null
    }

    # SPF: NIE blind einen zweiten v=spf1-Record hinzufuegen (RFC 7208 PermError, siehe Doku Punkt 4)
    $existingTxt = Invoke-Az @("network", "dns", "record-set", "txt", "show", "-g", $DnsZoneResourceGroup, "-z", $DnsZoneName, "-n", "@")
    $existingSpf = $existingTxt.TXTRecords | Where-Object { $_.value[0] -like "v=spf1*" }
    if ($existingSpf) {
        if ($existingSpf.value[0] -like "*include:spf.protection.outlook.com*") {
            Write-Host "Bestehender SPF-Record enthaelt schon 'include:spf.protection.outlook.com' - nichts zu tun."
        }
        else {
            Write-Warning "Es existiert bereits ein SPF-Record OHNE 'include:spf.protection.outlook.com': $($existingSpf.value[0])"
            Write-Warning "Bitte manuell mergen (NICHT automatisch einen zweiten v=spf1-Record anlegen, das bricht SPF fuer die ganze Domain)."
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($DnsZoneName, "Add TXT SPF record")) {
            Invoke-Az @("network", "dns", "record-set", "txt", "add-record", "-g", $DnsZoneResourceGroup, "-z", $DnsZoneName, "-n", "@", "-v", $records.SPF.value) | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($DnsZoneName, "Add DKIM CNAME records")) {
        Invoke-Az @("network", "dns", "record-set", "cname", "set-record", "-g", $DnsZoneResourceGroup, "-z", $DnsZoneName, "-n", $records.DKIM.name, "-c", $records.DKIM.value) | Out-Null
        Invoke-Az @("network", "dns", "record-set", "cname", "set-record", "-g", $DnsZoneResourceGroup, "-z", $DnsZoneName, "-n", $records.DKIM2.name, "-c", $records.DKIM2.value) | Out-Null
    }

    Write-Host "Warte kurz auf DNS-Propagation..."
    Start-Sleep -Seconds 30

    Write-Host "Stosse Verifizierung an..."
    foreach ($type in @("Domain", "SPF", "DKIM", "DKIM2")) {
        if ($PSCmdlet.ShouldProcess($DomainName, "Initiate $type verification")) {
            Invoke-Az @("communication", "email", "domain", "initiate-verification", "--domain-name", $DomainName, "--email-service-name", $EmailServiceName, "-g", $ResourceGroupName, "--verification-type", $type) | Out-Null
        }
    }

    Start-Sleep -Seconds 15
    $status = Invoke-Az @("communication", "email", "domain", "show", "--domain-name", $DomainName, "--email-service-name", $EmailServiceName, "-g", $ResourceGroupName)
    $status.verificationStates.PSObject.Properties | ForEach-Object { Write-Host "  $($_.Name): $($_.Value.status)" }
    Write-Host "(Falls noch nicht 'Verified': etwas warten und 'az communication email domain show ...' erneut aufrufen)"
}
else {
    Write-Host "`n-UseAzureDns nicht gesetzt: Records manuell eintragen, dann az communication email domain initiate-verification (Domain/SPF/DKIM/DKIM2) manuell aufrufen."
    Write-Host "Danach dieses Skript mit gleichen Parametern erneut laufen lassen (Ressourcen werden nicht doppelt angelegt) um mit Sender-Username/RBAC/SMTP-Username fortzufahren."
}

# ---- Sender Username ----
Write-Host "`nLege Sender-Username an: $SenderUsername@$DomainName"
if ($PSCmdlet.ShouldProcess($SenderUsername, "Create Sender Username")) {
    Invoke-Az @("communication", "email", "domain", "sender-username", "create", "--domain-name", $DomainName, "--email-service-name", $EmailServiceName, "-g", $ResourceGroupName, "--sender-username", $SenderUsername, "--username", $SenderUsername, "--display-name", $SenderDisplayName) | Out-Null
}

# ---- Domain mit Communication Service verknuepfen ----
$sub = if ($SubscriptionId) { $SubscriptionId } else { (Invoke-Az @("account", "show")).id }
$domainResourceId = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Communication/emailServices/$EmailServiceName/domains/$DomainName"
Write-Host "Verknuepfe Domain mit Communication Service..."
if ($PSCmdlet.ShouldProcess($CommServiceName, "Link domain")) {
    Invoke-Az @("communication", "update", "--name", $CommServiceName, "--resource-group", $ResourceGroupName, "--linked-domains", $domainResourceId) | Out-Null
}

# ---- RBAC-Rolle zuweisen ----
$commResourceId = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Communication/CommunicationServices/$CommServiceName"
Write-Host "Weise Rolle '$RoleName' der Entra-App zu..."
if ($PSCmdlet.ShouldProcess($EntraApplicationId, "Assign role $RoleName")) {
    try {
        Invoke-Az @("role", "assignment", "create", "--assignee", $EntraApplicationId, "--role", $RoleName, "--scope", $commResourceId) | Out-Null
    }
    catch {
        if ($_.Exception.Message -match "already exists") { Write-Host "Rollenzuweisung existiert bereits." }
        else { throw }
    }
}

# ---- SMTP-Username-Ressource anlegen (via REST + JSON-Datei, siehe Doku Punkt 2+3) ----
if ($SmtpLoginUsername -eq $SmtpUsernameResourceName) {
    throw "SmtpLoginUsername darf nicht gleich SmtpUsernameResourceName sein (wird von Azure abgelehnt)."
}

$tmpJson = Join-Path $env:TEMP "smtpuser-$CommServiceName.json"
@{
    properties = @{
        username           = $SmtpLoginUsername
        entraApplicationId = $EntraApplicationId
        tenantId            = $EntraTenantId
    }
} | ConvertTo-Json | Set-Content -Path $tmpJson -Encoding utf8

$restUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Communication/communicationServices/$CommServiceName/smtpUsernames/$($SmtpUsernameResourceName)?api-version=2025-09-01"
Write-Host "Lege SMTP-Username-Ressource an (Login-Name: $SmtpLoginUsername)..."
if ($PSCmdlet.ShouldProcess($SmtpUsernameResourceName, "Create SMTP username resource")) {
    Invoke-Az @("rest", "--method", "put", "--url", $restUrl, "--body", "@$tmpJson") | Out-Null
}
Remove-Item $tmpJson -ErrorAction SilentlyContinue

Write-Host "`nFertig. SMTP-Zugangsdaten fuer Send-MailMessage / Send-Notification:"
Write-Host "  Server:   smtp.azurecomm.net (Port 587, TLS)"
Write-Host "  Username: $SmtpLoginUsername"
Write-Host "  Passwort: Client Secret der Entra-App ($EntraApplicationId)"
Write-Host "  Absender: $SenderUsername@$DomainName"
