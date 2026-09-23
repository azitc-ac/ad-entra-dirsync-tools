#Requires -Version 5.1
<#
.SYNOPSIS
    Zeigt PTA-Authentifizierungsereignisse aus dem Windows Security Log.
.DESCRIPTION
    Liest den Security Log des PTA-Agent-Servers und gibt alle Authentifizierungsversuche
    aus, die vom AzureADConnectAuthenticationAgentService.exe verarbeitet wurden.
    Unterstützt Filterung nach Zeitraum und gibt menschenlesbare Status-Beschreibungen aus.
.PARAMETER Hours
    Anzahl der letzten Stunden, die durchsucht werden sollen. Standard: 1
.PARAMETER MaxEvents
    Maximale Anzahl der zurückgegebenen Ereignisse. Standard: 50
.EXAMPLE
    .\Get-PTAAuthEvents.ps1
    Zeigt PTA-Events der letzten Stunde.
.EXAMPLE
    .\Get-PTAAuthEvents.ps1 -Hours 24
    Zeigt PTA-Events der letzten 24 Stunden.
.EXAMPLE
    .\Get-PTAAuthEvents.ps1 -Hours 2 -MaxEvents 100
    Zeigt bis zu 100 PTA-Events der letzten 2 Stunden.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [int]$Hours = 1,

    [Parameter()]
    [int]$MaxEvents = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Status-Code-Tabellen
$statusCodes = @{
    '0x00000000' = 'Erfolgreich'
    '0xC000006D' = 'Falscher Benutzername oder falsches Passwort'
    '0xC000006E' = 'Account-Einschraenkung verletzt'
    '0xC000006F' = 'Anmeldezeit-Einschraenkung (Logon Hours)'
    '0xC0000070' = 'Workstation-Einschraenkung'
    '0xC0000071' = 'Passwort abgelaufen'
    '0xC0000072' = 'Account deaktiviert'
    '0xC0000193' = 'Account abgelaufen'
    '0xC0000224' = 'Passwortaenderung beim naechsten Login erforderlich'
    '0xC0000234' = 'Account gesperrt (Lockout)'
    '0xC0000413' = 'Authentifizierungsfirewall-Einschraenkung'
}

$subStatusCodes = @{
    '0xC000006F' = 'Ausserhalb der erlaubten Anmeldezeiten'
    '0xC0000070' = 'Anmeldung von dieser Workstation nicht erlaubt'
    '0xC0000071' = 'Passwort abgelaufen'
    '0xC0000072' = 'Account deaktiviert'
    '0xC0000193' = 'Account abgelaufen'
    '0xC0000224' = 'Passwortaenderung erforderlich'
    '0xC0000234' = 'Account gesperrt'
    '0x00000000' = '-'
}

$eventTypes = @{
    4624 = 'SUCCESS'
    4625 = 'FAILURE'
    4648 = 'EXPLICIT_CREDS'
}
#endregion

#region Hilfsfunktionen
function Resolve-StatusCode {
    param([string]$Code)
    if ($statusCodes.ContainsKey($Code)) { $statusCodes[$Code] }
    else { "Unbekannt ($Code)" }
}

function Resolve-SubStatusCode {
    param([string]$Code)
    if ($subStatusCodes.ContainsKey($Code)) { $subStatusCodes[$Code] }
    else { "Unbekannt ($Code)" }
}

function Get-PropertyValue {
    param(
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,
        [int]$Index,
        [string]$Default = '-'
    )
    try {
        $val = $Event.Properties[$Index].Value
        if ($null -eq $val -or $val -eq '') { $Default }
        else { $val.ToString() }
    }
    catch { $Default }
}

function Format-StatusHex {
    param($Value)
    try {
        $bytes = [System.BitConverter]::GetBytes([int32]$Value)
        $uint = [System.BitConverter]::ToUInt32($bytes, 0)
        '0x{0:X8}' -f $uint
    }
    catch { '0x00000000' }
}
#endregion

#region Audit-Policy pruefen
Write-Host "`nPruefe Audit-Policy..." -ForegroundColor Cyan
try {
    $auditOutput = auditpol /get /subcategory:"Logon" 2>&1
    if ($auditOutput -match 'No Auditing') {
        Write-Warning "Audit Logon Events ist deaktiviert! Aktiviere mit: auditpol /set /subcategory:'Logon' /success:enable /failure:enable"
    }
    elseif ($auditOutput -match 'Success and Failure') {
        Write-Host "Audit Logon Events: Success and Failure aktiv" -ForegroundColor Green
    }
    elseif ($auditOutput -match 'Success') {
        Write-Warning "Audit Logon Events: Nur Success aktiv (Failure-Events werden nicht erfasst)"
    }
    elseif ($auditOutput -match 'Failure') {
        Write-Warning "Audit Logon Events: Nur Failure aktiv (Success-Events werden nicht erfasst)"
    }
}
catch {
    Write-Warning "Audit-Policy konnte nicht geprueft werden: $_"
}
#endregion

#region XML-Filter aufbauen
$startTime = (Get-Date).AddHours(-$Hours).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z')
$ptaProcess = 'C:\Program Files\Microsoft Azure AD Connect Authentication Agent\AzureADConnectAuthenticationAgentService.exe'

# Event IDs: 4624 (Success), 4625 (Failure), 4648 (Explicit Creds)
$filterXml = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">
      *[System[
          (EventID=4624 or EventID=4625 or EventID=4648)
          and TimeCreated[@SystemTime&gt;='$startTime']
        ]
        and EventData[
          Data[@Name='ProcessName'] and Data='$ptaProcess'
        ]
      ]
    </Select>
  </Query>
</QueryList>
"@
#endregion

#region Events abrufen
Write-Host "Suche PTA-Events der letzten $Hours Stunde(n) (max. $MaxEvents Events)..." -ForegroundColor Cyan

try {
    $events = Get-WinEvent -FilterXml $filterXml -MaxEvents $MaxEvents -ErrorAction Stop
}
catch [System.Exception] {
    if ($_.Exception.Message -match 'No events were found') {
        Write-Host "`nKeine PTA-Events im angegebenen Zeitraum gefunden." -ForegroundColor Yellow
        Write-Host "Tipp: Zeitraum erweeitern mit -Hours Parameter, z.B.: .\Get-PTAAuthEvents.ps1 -Hours 24`n"
        exit 0
    }
    throw
}
#endregion

#region Events auswerten
$results = foreach ($event in $events) {
    $eventId = $event.Id
    $eventType = if ($eventTypes.ContainsKey($eventId)) { $eventTypes[$eventId] } else { "UNKNOWN($eventId)" }

    switch ($eventId) {
        4624 {
            # Erfolgreicher Login
            # Properties: 0=SubjectUserSid, 1=SubjectUserName, 2=SubjectDomainName,
            #             3=SubjectLogonId, 4=TargetUserSid, 5=TargetUserName,
            #             6=TargetDomainName, 7=TargetLogonId, 8=LogonType, ...
            $account    = Get-PropertyValue $event 5
            $domain     = Get-PropertyValue $event 6
            $statusHex  = '0x00000000'
            $subStatHex = '0x00000000'
            $statusDesc = 'Erfolgreich'
            $subStatDesc = '-'
        }
        4625 {
            # Fehlgeschlagener Login
            # Properties: 0=SubjectUserSid, 1=SubjectUserName, 2=SubjectDomainName,
            #             3=SubjectLogonId, 4=TargetUserSid, 5=TargetUserName,
            #             6=TargetDomainName, 7=Status, 8=FailureReason,
            #             9=SubStatus, 10=LogonType, ...
            $account    = Get-PropertyValue $event 5
            $domain     = Get-PropertyValue $event 6
            $statusHex  = Format-StatusHex (Get-PropertyValue $event 7 '0')
            $subStatHex = Format-StatusHex (Get-PropertyValue $event 9 '0')
            $statusDesc = Resolve-StatusCode $statusHex
            $subStatDesc = Resolve-SubStatusCode $subStatHex
        }
        4648 {
            # Explicit Credentials
            # Properties: 0=SubjectUserSid, 1=SubjectUserName, 2=SubjectDomainName,
            #             3=SubjectLogonId, 4=LogonGuid, 5=TargetUserName,
            #             6=TargetDomainName, ...
            $account    = Get-PropertyValue $event 5
            $domain     = Get-PropertyValue $event 6
            $statusHex  = '-'
            $subStatHex = '-'
            $statusDesc = 'Credentials uebergeben'
            $subStatDesc = '-'
        }
        default {
            $account = '-'; $domain = '-'
            $statusHex = '-'; $subStatHex = '-'
            $statusDesc = '-'; $subStatDesc = '-'
        }
    }

    [PSCustomObject]@{
        Zeit        = $event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        EventID     = $eventId
        Typ         = $eventType
        Account     = if ($domain -ne '-' -and $domain -ne '') { "$domain\$account" } else { $account }
        Status      = $statusHex
        SubStatus   = $subStatHex
        Beschreibung = $statusDesc
        Detail      = $subStatDesc
    }
}
#endregion

#region Ausgabe
Write-Host "`n=== PTA-Authentifizierungsereignisse (letzte $Hours Stunde(n)) ===" -ForegroundColor Cyan
Write-Host "Zeitraum: $(Get-Date (Get-Date).AddHours(-$Hours) -Format 'yyyy-MM-dd HH:mm:ss') bis $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Gefunden: $($results.Count) Event(s)`n"

$results | Format-Table -AutoSize -Wrap

# Zusammenfassung
$success  = @($results | Where-Object Typ -eq 'SUCCESS').Count
$failure  = @($results | Where-Object Typ -eq 'FAILURE').Count
$explicit = @($results | Where-Object Typ -eq 'EXPLICIT_CREDS').Count

Write-Host "`n=== Zusammenfassung ===" -ForegroundColor Cyan
Write-Host "Erfolgreich:          $success" -ForegroundColor Green
Write-Host "Fehlgeschlagen:       $failure" -ForegroundColor Red
Write-Host "Explicit Credentials: $explicit" -ForegroundColor Yellow

# Haeufigste Fehlergruende
$failureGroups = $results | Where-Object Typ -eq 'FAILURE' | Group-Object Beschreibung | Sort-Object Count -Descending
if ($failureGroups) {
    Write-Host "`n=== Fehlerursachen ===" -ForegroundColor Cyan
    $failureGroups | ForEach-Object {
        Write-Host "  $($_.Count)x  $($_.Name)" -ForegroundColor Red
    }
}
Write-Host ""
#endregion
