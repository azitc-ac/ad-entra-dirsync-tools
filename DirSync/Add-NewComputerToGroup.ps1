#Requires -RunAsAdministrator
# Add-NewComputerToGroup.ps1
#
# Nimmt neu angelegte Computerkonten (Security-Event 4741) automatisch in eine AD-Gruppe auf.
# Hintergrund Hybrid Identity: Die Gruppe (Standard SYNC-Devices-to-ENTRA) dient als Scope-Filter der
# Synchronisation nach Entra ID - ein neues Computerobjekt wird erst nach der Aufnahme dort sichtbar.
# Das Skript automatisiert nur diese Aufnahme; Scoping und Sync-Konfiguration bleiben ausserhalb.
#
#
#   .\Add-NewComputerToGroup.ps1 -CheckPol      Prüft, ob die Audit-Policy das Event 4741 erzeugt
#   .\Add-NewComputerToGroup.ps1 -CreateTask    Komplett-Setup: fragt die Zielgruppe ab, delegiert das Schreibrecht
#                                               auf 'member' an das Computerkonto des DC, legt den Task an (läuft
#                                               als SYSTEM) und testet ihn. Mit -UseGmsa stattdessen gMSA.
#   Optional -OuDn "<OU-DN>" [,"<OU-DN2>" ...]  bzw. "DN1;DN2": nur Computer aufnehmen, deren Konto in einer
#                             dieser OUs (inkl. Unter-OUs) liegt. Trenner ist ';' (DNs enthalten selbst Kommas).
#                             Geprüft wird der Ort zum Zeitpunkt des Events - wird das Konto erst danach
#                             verschoben, wird es nicht erfasst.
#   .\Add-NewComputerToGroup.ps1 -RemoveGmsa    Räumt das nicht mehr benötigte gMSA samt Rechten auf (mit Rückfrage)
#   .\Add-NewComputerToGroup.ps1 -GroupName X -ComputerSam NAME$
#                                               Nimmt genau dieses Konto auf. So ruft der Task das Skript auf: der
#                                               Event-Trigger reicht TargetUserName aus Event 4741 durch - das Skript
#                                               muss das (bei grossem Security-Log minutenlange) Log nicht durchsuchen.
#   .\Add-NewComputerToGroup.ps1 [-GroupName X] Ohne -ComputerSam: durchsucht das Security-Log nach 4741-Events
#                                               der letzten -LookbackMinutes (Nachholen; auf grossen Logs langsam)
#
# Pro DC einrichten: Event 4741 entsteht nur auf dem DC, auf dem das Konto angelegt wurde.
# Das Skript muss am Ort bleiben - der Task verweist auf diesen Pfad.
# Auf jedem DC ausführen; Delegation (und ggf. gMSA) sind idempotent.

[CmdletBinding(DefaultParameterSetName = "Run")]
param(
    [Parameter(ParameterSetName = "Check")]  [switch] $CheckPol,
    [Parameter(ParameterSetName = "Create")] [switch] $CreateTask,
    [Parameter(ParameterSetName = "Cleanup")] [switch] $RemoveGmsa,

    # Zielgruppe (sAMAccountName). Bei -CreateTask: ohne Angabe wird abgefragt und im Task als
    # Parameter hinterlegt. Im Standardlauf ohne Angabe: SYNC-Devices-to-ENTRA.
    [string] $GroupName       = "",
    # Standard: Task läuft als SYSTEM; das Schreibrecht auf die Gruppe bekommt das Computerkonto des DC.
    # Mit -UseGmsa stattdessen ein gMSA anlegen/verwenden (braucht KDS-Root-Key und 'Log on as a batch job').
    [switch] $UseGmsa,
    # gMSA-Name für -UseGmsa (max. 14 Zeichen + '$')
    [string] $GmsaName        = "gmsa-grpsync",
    # Override: fertiges Konto verwenden ("SYSTEM", "DOMAIN\svc-x" oder "DOMAIN\gmsa$"); es werden keine Rechte vergeben.
    [string] $TaskUser        = "",
    [string] $TaskName        = "ADWeb - Neue Computer in Gruppe aufnehmen",
    # Nur Lab: legt einen sofort wirksamen KDS-Root-Key an, falls keiner existiert (gMSA braucht ihn)
    [switch] $CreateKdsRootKey,
    # Rückfrage vor dem Umsetzen überspringen
    [switch] $Yes,
    # Nur Computer in diesen OUs (inkl. Unter-OUs) aufnehmen, z. B. "OU=Autopilot,OU=Clients,DC=example,DC=com".
    # Mehrere: -OuDn 'DN1','DN2' oder "DN1;DN2". Bei -CreateTask: ohne Angabe wird abgefragt (leer = alle Computer)
    # und im Task als Parameter hinterlegt.
    [string[]] $OuDn          = @(),
    # Einzelnes Konto (sAMAccountName, z. B. "PC1$"); vom Task per Event-Daten befüllt.
    [string] $ComputerSam     = "",
    [int]    $LookbackMinutes = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -OuDn normalisieren: Array und/oder ';'-getrennte Einträge -> saubere Liste (DNs enthalten selbst Kommas)
$OuList = @($OuDn | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$DefaultGroup  = "SYNC-Devices-to-ENTRA"
$DataDir       = Join-Path $env:ProgramData "ADWeb"
$LogFile       = Join-Path $DataDir "Add-NewComputerToGroup.log"

# GUID der Audit-Unterkategorie "Computer Account Management" (sprachunabhängig, anders als der Name)
$AuditSubcategoryGuid = [Guid]"0CCE9236-69AE-11D9-BED3-505054503030"
# schemaIDGUID des Attributs 'member'
$MemberAttrGuid       = [Guid]"bf9679c0-0de6-11d0-a285-00aa003049e2"

function Write-Log {
    param([string] $Message)
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    try {
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

# ── -CheckPol ────────────────────────────────────────────────────────────────

function Get-AuditSetting {
    # Effektive Audit-Policy via AuditQuerySystemPolicy: 1 = Success, 2 = Failure, 4 = No Auditing
    if (-not ("AdwebAuditPol" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AdwebAuditPol {
    [StructLayout(LayoutKind.Sequential)]
    public struct AUDIT_POLICY_INFORMATION {
        public Guid AuditSubCategoryGuid;
        public uint AuditingInformation;
        public Guid AuditCategoryGuid;
    }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AuditQuerySystemPolicy([In] Guid[] pSubCategoryGuids, uint dwPolicyCount, out IntPtr ppAuditPolicy);
    [DllImport("advapi32.dll")]
    static extern void AuditFree(IntPtr buffer);
    public static uint Query(Guid sub) {
        IntPtr p;
        if (!AuditQuerySystemPolicy(new Guid[] { sub }, 1, out p))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            AUDIT_POLICY_INFORMATION i = (AUDIT_POLICY_INFORMATION)Marshal.PtrToStructure(p, typeof(AUDIT_POLICY_INFORMATION));
            return i.AuditingInformation;
        } finally { AuditFree(p); }
    }
}
"@
    }
    return [AdwebAuditPol]::Query($AuditSubcategoryGuid)
}

function Test-AuditPolicy {
    # $true = Event 4741 wird geschrieben. Gibt bei $false die Anleitung aus.
    $flags = Get-AuditSetting
    if ($flags -band 1) {
        Write-Host "OK: 'Audit Computer Account Management' ist aktiv (Success) - Event 4741 wird geschrieben." -ForegroundColor Green
        return $true
    }
    Write-Host "FEHLT: 'Audit Computer Account Management' protokolliert keine Erfolge - Event 4741 entsteht nicht." -ForegroundColor Red
    Write-Host @"

So aktivieren (per GPO, damit es nicht überschrieben wird):
  1. gpmc.msc -> 'Default Domain Controllers Policy' bearbeiten
  2. Computer Configuration > Policies > Windows Settings > Security Settings >
     Advanced Audit Policy Configuration > Audit Policies > Account Management >
     'Audit Computer Account Management' -> 'Configure the following audit events' + 'Success'
  3. Auf dem DC: gpupdate /force   und dieses Skript mit -CheckPol erneut ausführen.

Falls es danach trotzdem 'fehlt' meldet: Die klassische Richtlinie 'Audit account management'
(Security Settings > Local Policies > Audit Policy) überschreibt die erweiterte. Dann in
Local Policies > Security Options 'Audit: Force audit policy subcategory settings ... to override
audit policy category settings' auf Enabled setzen.

Nur zum schnellen Test (wird von der GPO wieder überschrieben):
  auditpol /set /subcategory:"{$AuditSubcategoryGuid}" /success:enable
"@
    return $false
}

# ── -CreateTask: Setup ───────────────────────────────────────────────────────

function Read-TargetGroup {
    # Gruppe abfragen (oder aus -GroupName), gegen AD validieren, DN zurückgeben
    $name = $GroupName
    $default = $DefaultGroup
    while ($true) {
        if (-not $name) {
            $in = Read-Host "Zielgruppe, in die neue Computer aufgenommen werden [$default]"
            $name = if ($in) { $in.Trim() } else { $default }
        }
        $g = Get-ADGroup -Filter "SamAccountName -eq '$($name -replace "'", "''")'" -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($g) { return $g }
        if ($GroupName) { throw "Gruppe '$name' nicht gefunden." }
        Write-Host "Gruppe '$name' nicht gefunden - bitte erneut eingeben." -ForegroundColor Yellow
        $name = ""
    }
}

function Read-TargetOu {
    # OUs abfragen (oder aus -OuDn), gegen AD validieren; leer = keine Einschränkung. Gibt die DNs zurück.
    $list = $OuList
    while ($true) {
        if ($list.Count -eq 0 -and $OuList.Count -eq 0) {
            $in = (Read-Host "Nur Computer aus diesen OUs aufnehmen (DNs, mehrere mit ';' trennen, z. B. OU=Autopilot,OU=Clients,DC=example,DC=com; leer = alle)").Trim()
            $list = @($in -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        if ($list.Count -eq 0) { return @() }
        $ok = @(); $bad = @()
        foreach ($dn in $list) {
            if ($dn -match '["`]') { throw 'OU-DN enthält unzulässige Zeichen (doppeltes Anführungszeichen oder Backtick).' }
            $ou = Get-ADObject -Identity $dn -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue
            if ($ou -and $ou.ObjectClass -in "organizationalUnit", "container") { $ok += $ou.DistinguishedName } else { $bad += $dn }
        }
        if ($bad.Count -eq 0) { return $ok }
        if ($OuList.Count -gt 0) { throw ("OU nicht gefunden: " + ($bad -join " | ")) }
        Write-Host ("Nicht gefunden: " + ($bad -join " | ") + " - bitte alle erneut eingeben (leer = alle).") -ForegroundColor Yellow
        $list = @()
    }
}

function Confirm-Step {
    param([string] $Question)
    if ($Yes) { return }
    $a = Read-Host "$Question (j/N)"
    if ($a -notmatch '^(j|ja|y|yes)$') { throw "Abgebrochen." }
}

function Ensure-Gmsa {
    # Legt das gMSA an (falls fehlend), erlaubt diesem DC das Kennwort-Abrufen, installiert es lokal.
    param([string] $Name, $DcComputer)
    $sam = $Name + '$'
    $dnsRoot = (Get-ADDomain -Server $env:COMPUTERNAME).DNSRoot

    if (-not (Get-KdsRootKey)) {
        if ($CreateKdsRootKey) {
            Write-Host "Kein KDS-Root-Key vorhanden - lege sofort wirksamen Key an (nur für Lab geeignet)." -ForegroundColor Yellow
            Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
        } else {
            throw ("Kein KDS-Root-Key in der Domäne - gMSAs sind ohne ihn nicht möglich. " +
                   "Produktiv: Add-KdsRootKey -EffectiveImmediately (wirkt nach ca. 10 h). " +
                   "Lab: dieses Skript mit -CreateKdsRootKey erneut starten.")
        }
    }

    $existing = Get-ADServiceAccount -Filter "SamAccountName -eq '$sam'" -Properties PrincipalsAllowedToRetrieveManagedPassword -Server $env:COMPUTERNAME
    if (-not $existing) {
        New-ADServiceAccount -Name $Name -DNSHostName "$Name.$dnsRoot" `
            -PrincipalsAllowedToRetrieveManagedPassword $DcComputer.DistinguishedName `
            -Description "ADWeb: nimmt neue Computerkonten in eine Gruppe auf (Event 4741)" `
            -Enabled $true -Server $env:COMPUTERNAME
        Write-Host "gMSA angelegt: $sam" -ForegroundColor Green
    } else {
        $allowed = @($existing.PrincipalsAllowedToRetrieveManagedPassword)
        if ($allowed -notcontains $DcComputer.DistinguishedName) {
            Set-ADServiceAccount -Identity $Name `
                -PrincipalsAllowedToRetrieveManagedPassword ($allowed + $DcComputer.DistinguishedName) -Server $env:COMPUTERNAME
            Write-Host "DC '$($DcComputer.Name)' darf das Kennwort von $sam abrufen (ergänzt)." -ForegroundColor Green
        } else {
            Write-Host "gMSA $sam existiert, DC ist bereits berechtigt." -ForegroundColor DarkGray
        }
    }

    Install-ADServiceAccount -Identity $Name
    if (-not (Test-ADServiceAccount -Identity $Name)) {
        throw "Test-ADServiceAccount '$Name' schlägt fehl (KDS-Key noch nicht wirksam/repliziert oder DC nicht berechtigt)."
    }
    Write-Host "gMSA lokal installiert, Test-ADServiceAccount = True." -ForegroundColor Green
    return Get-ADServiceAccount -Identity $Name -Server $env:COMPUTERNAME
}

function Grant-GroupWrite {
    # Delegiert NUR Schreiben auf das Attribut 'member' dieser einen Gruppe (kein Domain Admin nötig).
    param($Group, $Account)
    $path = "AD:\" + $Group.DistinguishedName
    $acl  = Get-Acl -Path $path
    $has  = $acl.Access | Where-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $Account.SID.Value -and
        $_.ObjectType -eq $MemberAttrGuid -and $_.AccessControlType -eq "Allow" -and
        ($_.ActiveDirectoryRights -band [DirectoryServices.ActiveDirectoryRights]::WriteProperty)
    }
    if ($has) { Write-Host "Delegation 'member schreiben' auf '$($Group.Name)' besteht bereits." -ForegroundColor DarkGray; return }
    $rule = New-Object DirectoryServices.ActiveDirectoryAccessRule(
        $Account.SID,
        [DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [Security.AccessControl.AccessControlType]::Allow,
        $MemberAttrGuid,
        [DirectoryServices.ActiveDirectorySecurityInheritance]::None)
    $acl.AddAccessRule($rule)
    Set-Acl -Path $path -AclObject $acl
    Write-Host "Delegiert: $($Account.SamAccountName) darf 'member' von '$($Group.Name)' schreiben." -ForegroundColor Green
}

function Grant-EventLogRead {
    # Security-Log lesen: Mitglied der Builtin-Gruppe 'Event Log Readers' (S-1-5-32-573)
    param($Account)
    $elr = Get-ADGroup -Identity "S-1-5-32-573" -Server $env:COMPUTERNAME
    $isMember = Get-ADGroupMember -Identity $elr -Server $env:COMPUTERNAME | Where-Object { $_.SID -eq $Account.SID }
    if ($isMember) { Write-Host "$($Account.SamAccountName) ist bereits in 'Event Log Readers'." -ForegroundColor DarkGray; return }
    Add-ADGroupMember -Identity $elr -Members $Account -Server $env:COMPUTERNAME
    Write-Host "$($Account.SamAccountName) zu 'Event Log Readers' hinzugefügt." -ForegroundColor Green
}

function Get-RightSids {
    # SIDs eines Rechts aus dem secedit-Export (Einträge: "*S-1-..." oder Kontonamen)
    param([string[]] $Lines, [string] $Right)
    $line = $Lines | Where-Object { $_ -match ('^\s*' + $Right + '\s*=') } | Select-Object -First 1
    $sids = @()
    if ($line) {
        foreach ($tok in (($line -split '=', 2)[1] -split ',')) {
            $t = $tok.Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('*')) { $sids += $t.Substring(1); continue }
            try { $sids += (New-Object Security.Principal.NTAccount $t).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
        }
    }
    return ,$sids
}

function Test-BatchLogonRight {
    # Hat das Konto (direkt oder über Gruppen) effektiv "Log on as a batch job" UND ist nicht über
    # "Deny log on as a batch job" gesperrt (Deny gewinnt)? Nur prüfen + Hinweis, nichts ändern -
    # das Recht gehört in die GPO (lokale Änderungen würden überschrieben).
    param($Account)
    $tmp = Join-Path $env:TEMP ("ur-{0}.inf" -f [Guid]::NewGuid())
    try {
        & secedit.exe /export /cfg $tmp /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { throw "secedit /export fehlgeschlagen (Exit $LASTEXITCODE)." }
        $lines = @(Get-Content $tmp -Encoding Unicode)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }

    $granted = Get-RightSids -Lines $lines -Right "SeBatchLogonRight"
    $denied  = Get-RightSids -Lines $lines -Right "SeDenyBatchLogonRight"

    # Token des Kontos: eigene SID + alle (verschachtelten) Gruppen-SIDs
    $mine = @($Account.SID.Value)
    $obj  = Get-ADObject -Identity $Account.DistinguishedName -Properties tokenGroups -Server $env:COMPUTERNAME
    foreach ($g in @($obj.tokenGroups)) {
        # je nach Modulversion SecurityIdentifier, byte[] oder String
        if     ($g -is [Security.Principal.SecurityIdentifier]) { $mine += $g.Value }
        elseif ($g -is [byte[]]) { $mine += ([Security.Principal.SecurityIdentifier]::new([byte[]]$g, 0)).Value }
        else   { $mine += ([Security.Principal.SecurityIdentifier]::new([string]$g)).Value }
    }

    $deny = $mine | Where-Object { $denied -contains $_ } | Select-Object -First 1
    if ($deny) {
        Write-Host "FEHLT: '$($Account.SamAccountName)' ist über $deny von 'Deny log on as a batch job' erfasst - Deny gewinnt immer." -ForegroundColor Red
        Write-Host "  Dieses SID aus 'Deny log on as a batch job' (GPO, Local Policies > User Rights Assignment) entfernen" -ForegroundColor Red
        Write-Host "  oder das Task-Konto aus der betroffenen Gruppe herausnehmen." -ForegroundColor Red
        return $false
    }
    $hit = $mine | Where-Object { $granted -contains $_ } | Select-Object -First 1
    if ($hit) {
        Write-Host "OK (laut secedit): '$($Account.SamAccountName)' hat 'Log on as a batch job' (über $hit), kein Deny. Maßgeblich bleibt der Testlauf." -ForegroundColor Green
        return $true
    }
    Write-Host "FEHLT: '$($Account.SamAccountName)' hat effektiv NICHT 'Log on as a batch job' - der Task würde nicht starten." -ForegroundColor Red
    Write-Host @"
  Per GPO vergeben (lokal gesetzt würde es überschrieben):
    gpmc.msc -> 'Default Domain Controllers Policy' > Computer Configuration > Policies > Windows Settings >
    Security Settings > Local Policies > User Rights Assignment > 'Log on as a batch job'
    -> eine Gruppe, die '$($Account.SamAccountName)' enthält (oder das Konto selbst), HINZUFÜGEN.
  ACHTUNG: Die Einstellung ersetzt die Liste. Ist sie in der GPO noch nicht definiert, zuerst die bisherigen
    Standardeinträge (z. B. Administrators, Backup Operators, Performance Log Users) mit eintragen.
  Danach auf dem DC: gpupdate /force  und dieses Skript erneut ausführen.
"@
    return $false
}

function Register-EventTask {
    param([string] $RunAs, [bool] $RunAsIsGmsa, [bool] $RunAsIsSystem, [string] $TargetGroup, [string[]] $TargetOu = @())
    $scriptPath = $PSCommandPath
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GroupName "{1}" -ComputerSam "$(TargetUser)"' -f $scriptPath, $TargetGroup
    if ($TargetOu.Count -gt 0) { $taskArgs += (' -OuDn "{0}"' -f ($TargetOu -join ';')) }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs

    # Event-Trigger: Security-Log, EventID 4741 (A computer account was created)
    $class   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Enabled      = $true
    $trigger.Subscription = '<QueryList><Query Id="0" Path="Security"><Select Path="Security">*[System[(EventID=4741)]]</Select></Query></QueryList>'
    # Event-Daten an die Aktion durchreichen: $(TargetUser) im Argument = TargetUserName des Events
    $nvClass = Get-CimClass -ClassName MSFT_TaskNamedValue -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger.ValueQueries = [Microsoft.Management.Infrastructure.CimInstance[]]@(
        (New-CimInstance -CimClass $nvClass -ClientOnly -Property @{ Name = "TargetUser"; Value = "Event/EventData/Data[@Name='TargetUserName']" }))

    # Mehrere Events kurz hintereinander: Läufe nacheinander abarbeiten, nie parallel
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances Queue -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $reg = @{
        TaskName    = $TaskName
        Action      = $action
        Trigger     = $trigger
        Settings    = $settings
        Description = "Nimmt neue Computerkonten (Event 4741) in die Gruppe '$TargetGroup' auf" + $(if ($TargetOu.Count -gt 0) { " (nur OUs: " + ($TargetOu -join ' | ') + ")" } else { "" }) + ". Skript: $scriptPath"
        Force       = $true      # Anlegen und Erneuern teilen sich diesen Pfad
    }
    if ($RunAsIsSystem) {
        $reg.Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    } elseif ($RunAsIsGmsa) {
        $reg.Principal = New-ScheduledTaskPrincipal -UserId $RunAs -LogonType Password -RunLevel Highest
    } else {
        $cred = Get-Credential -UserName $RunAs -Message "Kennwort für den Task-Account"
        $reg.User     = $cred.UserName
        $reg.Password = $cred.GetNetworkCredential().Password
        $reg.RunLevel = "Highest"
    }
    Register-ScheduledTask @reg | Out-Null

    # Beweis, dass die Durchreichung wirklich im Task steht (sonst bekäme das Skript nie einen Kontonamen)
    $xml = (Export-ScheduledTask -TaskName $TaskName) | Out-String
    if ($xml -notmatch 'ValueQueries' -or $xml -notmatch "TargetUserName" -or $xml -notmatch '\$\(TargetUser\)') {
        throw "Task wurde angelegt, enthält aber die Event-Datenübergabe (ValueQueries) nicht - Task bitte nicht verwenden. Task-XML: Export-ScheduledTask -TaskName `"$TaskName`""
    }
    Write-Host "Task-Definition geprüft: Event-Datenübergabe (TargetUserName -> -ComputerSam) ist enthalten." -ForegroundColor Green
}

function Test-TaskRun {
    # Beweist Logon-Recht, AD-Modul, Security-Log-Zugriff und Gruppenauflösung unter dem Task-Konto.
    # Start-ScheduledTask kehrt sofort zurück; "fertig" erst, wenn LastRunTime nach dem Start liegt
    # und der Task nicht mehr läuft (0x41303 = noch nie gelaufen, 0x41301 = läuft).
    $before = Get-Date
    Start-ScheduledTask -TaskName $TaskName
    $info = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        $info  = Get-ScheduledTaskInfo -TaskName $TaskName
        $state = (Get-ScheduledTask -TaskName $TaskName).State
        if ($info.LastRunTime -ge $before.AddSeconds(-2) -and $state -ne "Running" -and $info.LastTaskResult -ne 0x41301) { break }
    }
    $code = [uint32]$info.LastTaskResult
    if ($info.LastRunTime -lt $before.AddSeconds(-2) -or $code -eq 0x41303 -or $code -eq 0x41301) {
        Write-Host ("Testlauf UNKLAR: Task ist nach 60 s nicht gelaufen/fertig (LastTaskResult 0x{0:X}). " -f $code) -ForegroundColor Red
        Write-Host "Prüfen: Get-ScheduledTaskInfo -TaskName `"$TaskName`" | fl   und   Get-Content `"$LogFile`" -Tail 10" -ForegroundColor Red
        return $false
    }
    if ($code -eq 0) {
        Write-Host "Testlauf OK (LastTaskResult 0). Letzte Log-Zeilen:" -ForegroundColor Green
        if (Test-Path $LogFile) { Get-Content $LogFile -Tail 3 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" } }
        return $true
    }
    Write-Host ("Testlauf FEHLGESCHLAGEN (LastTaskResult 0x{0:X}). Log: {1}" -f $code, $LogFile) -ForegroundColor Red
    if ($code -eq 0x80070569) {
        Write-Host "0x80070569 = Anmeldeart nicht gewährt: dem Task-Konto fehlt 'Log on as a batch job' (siehe Hinweis oben)." -ForegroundColor Red
    } elseif ($code -eq 0x8007052E -or $code -eq 0x80070005) {
        Write-Host "Anmeldung/Zugriff verweigert: gMSA-Kennwortabruf (DC berechtigt? Test-ADServiceAccount) bzw. Ordnerrechte prüfen." -ForegroundColor Red
    } elseif ($code -eq 1) {
        Write-Host "Das Skript selbst ist mit Fehler beendet (Exit 1) - Ursache steht im Log." -ForegroundColor Red
    }
    return $false
}

function New-EventTask {
    foreach ($m in "ScheduledTasks", "ActiveDirectory") {
        if (-not (Get-Module -ListAvailable -Name $m)) { throw "Modul '$m' nicht verfügbar." }
    }
    Import-Module ActiveDirectory

    $policyOk = Test-AuditPolicy
    if (-not $policyOk) {
        Write-Host "`nHinweis: Setup läuft trotzdem durch, der Task feuert aber erst, wenn die Policy aktiv ist.`n" -ForegroundColor Yellow
    }

    $group = Read-TargetGroup
    $targetOus = @(Read-TargetOu)
    $dcComputer = Get-ADComputer -Identity $env:COMPUTERNAME -Server $env:COMPUTERNAME
    $netbios = (Get-ADDomain -Server $env:COMPUTERNAME).NetBIOSName

    $runGmsa   = [bool]$UseGmsa -and -not $TaskUser
    $runSystem = ($TaskUser -eq "SYSTEM") -or (-not [bool]$UseGmsa -and -not $TaskUser)
    $runAs = if ($runGmsa) { "$netbios\$GmsaName`$" } elseif ($runSystem) { "SYSTEM" } else { $TaskUser }
    Write-Host "`nGeplant auf diesem DC ($env:COMPUTERNAME):"
    Write-Host "  Zielgruppe        : $($group.Name)  ($($group.DistinguishedName))"
    if ($targetOus.Count -eq 0) { Write-Host "  Nur aus OU        : (keine Einschränkung - alle neuen Computer)" }
    else { foreach ($o in $targetOus) { Write-Host "  Nur aus OU        : $o (inkl. Unter-OUs)" } }
    if ($runGmsa) {
        Write-Host "  gMSA              : $runAs anlegen/ergänzen, installieren"
        Write-Host "  Delegation        : '$runAs' darf nur 'member' von '$($group.Name)' schreiben"
        Write-Host "  Event Log Readers : '$runAs' aufnehmen (Security-Log lesen)"
    } elseif ($runSystem -and -not $TaskUser) {
        Write-Host "  Task-Konto        : SYSTEM"
        Write-Host "  Delegation        : Computerkonto '$($dcComputer.SamAccountName)' darf nur 'member' von '$($group.Name)' schreiben"
    } else {
        Write-Host "  Task-Konto        : $runAs (vorhanden vorausgesetzt - keine Rechte werden vergeben)"
    }
    Write-Host "  Task              : '$TaskName' (Trigger: Event 4741, Aufruf mit -GroupName `"$($group.SamAccountName)`"$(if ($targetOus.Count -gt 0) { ' -OuDn ...' })), anschließend Testlauf"
    Confirm-Step "Umsetzen?"

    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

    $batchOk = $true
    if ($runGmsa) {
        $gmsa = Ensure-Gmsa -Name $GmsaName -DcComputer $dcComputer
        Grant-GroupWrite -Group $group -Account $gmsa
        Grant-EventLogRead -Account $gmsa
        & icacls.exe $DataDir /grant ("{0}:(OI)(CI)M" -f $runAs) | Out-Null     # Log schreiben unter dem Task-Konto
        if ($LASTEXITCODE -ne 0) { throw "icacls auf '$DataDir' für '$runAs' fehlgeschlagen." }
        $batchOk = Test-BatchLogonRight -Account $gmsa
    } elseif ($runSystem -and -not $TaskUser) {
        # SYSTEM authentifiziert sich im AD als Computerkonto des DC -> dieses bekommt das enge Schreibrecht
        Grant-GroupWrite -Group $group -Account $dcComputer
    } elseif ($TaskUser -eq "SYSTEM") {
        Write-Host "Warnung: -TaskUser SYSTEM ohne Delegation: das Computerkonto des DC hat normalerweise KEIN Schreibrecht auf '$($group.Name)'." -ForegroundColor Yellow
    }

    Register-EventTask -RunAs $runAs -RunAsIsGmsa ($runGmsa -or (-not $runSystem -and $TaskUser.EndsWith('$'))) -RunAsIsSystem $runSystem -TargetGroup $group.SamAccountName -TargetOu $targetOus
    $t = Get-ScheduledTask -TaskName $TaskName
    Write-Host "Task angelegt: '$($t.TaskName)' (läuft als $($t.Principal.UserId))" -ForegroundColor Green

    $ok = Test-TaskRun
    if (-not $batchOk) { $ok = $false }
    Write-Host "`nEntfernen: Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false"
    if (-not $ok) { exit 1 }
}

# ── -RemoveGmsa: Aufräumen ───────────────────────────────────────────────────

function Remove-GmsaSetup {
    # Entfernt in dieser Reihenfolge (sonst bleiben verwaiste Einträge): Schreibrecht auf der Gruppe,
    # Mitgliedschaften (Event Log Readers, Performance Log Users), Ordnerrecht, gMSA selbst.
    # Der KDS-Root-Key bleibt - er gehört der Domäne und kann anderweitig gebraucht werden.
    Import-Module ActiveDirectory
    $sam = $GmsaName + '$'
    $gmsa = Get-ADServiceAccount -Filter "SamAccountName -eq '$sam'" -Server $env:COMPUTERNAME
    if (-not $gmsa) { Write-Host "gMSA '$sam' existiert nicht - nichts aufzuräumen." -ForegroundColor DarkGray; return }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.Principal.UserId -like "*$GmsaName*") {
        throw "Der Task '$TaskName' läuft noch als $($task.Principal.UserId). Erst '-CreateTask' ausführen (stellt auf SYSTEM um), dann aufräumen."
    }

    $targetName = if ($GroupName) { $GroupName } else { $DefaultGroup }
    $group = Get-ADGroup -Filter "SamAccountName -eq '$targetName'" -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue
    $builtin = @(
        @{ Sid = "S-1-5-32-573"; Name = "Event Log Readers" },
        @{ Sid = "S-1-5-32-559"; Name = "Performance Log Users" }
    )
    $memberOf = @()
    foreach ($b in $builtin) {
        $grp = Get-ADGroup -Identity $b.Sid -Server $env:COMPUTERNAME
        if (Get-ADGroupMember -Identity $grp -Server $env:COMPUTERNAME | Where-Object { $_.SID -eq $gmsa.SID }) { $memberOf += $grp }
    }

    Write-Host "`nAufräumen auf diesem DC ($env:COMPUTERNAME) - folgendes wird entfernt:"
    if ($group) { Write-Host "  Schreibrecht ('member') von $sam auf '$($group.Name)'" }
    foreach ($g in $memberOf) { Write-Host "  Mitgliedschaft von $sam in '$($g.Name)'" }
    Write-Host "  Ordnerrecht von $sam auf $DataDir"
    Write-Host "  gMSA $sam selbst (Uninstall-ADServiceAccount + Remove-ADServiceAccount)"
    Write-Host "  Bleibt: KDS-Root-Key, andere DCs (dort vorher Uninstall-ADServiceAccount nötig, falls installiert)" -ForegroundColor DarkGray
    Confirm-Step "Wirklich entfernen?"

    if ($group) {
        $path = "AD:\" + $group.DistinguishedName
        $acl  = Get-Acl -Path $path
        $mine = @($acl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $gmsa.SID.Value -and
            $_.ObjectType -eq $MemberAttrGuid -and $_.AccessControlType -eq "Allow"
        })
        foreach ($r in $mine) { [void]$acl.RemoveAccessRule($r) }
        if ($mine.Count) { Set-Acl -Path $path -AclObject $acl; Write-Host "Schreibrecht entfernt ($($mine.Count) Eintrag/Einträge)." -ForegroundColor Green }
        else { Write-Host "Kein Schreibrecht des gMSA auf der Gruppe gefunden." -ForegroundColor DarkGray }
    }
    foreach ($g in $memberOf) {
        Remove-ADGroupMember -Identity $g -Members $gmsa -Confirm:$false -Server $env:COMPUTERNAME
        Write-Host "Aus '$($g.Name)' entfernt." -ForegroundColor Green
    }
    $netbios = (Get-ADDomain -Server $env:COMPUTERNAME).NetBIOSName
    if (Test-Path $DataDir) { & icacls.exe $DataDir /remove ("{0}\{1}`$" -f $netbios, $GmsaName) | Out-Null }
    try { Uninstall-ADServiceAccount -Identity $gmsa -Confirm:$false } catch { Write-Host "Uninstall-ADServiceAccount: $($_.Exception.Message)" -ForegroundColor Yellow }
    Remove-ADServiceAccount -Identity $gmsa -Confirm:$false -Server $env:COMPUTERNAME
    if (Get-ADServiceAccount -Filter "SamAccountName -eq '$sam'" -Server $env:COMPUTERNAME) { throw "gMSA '$sam' ist nach Remove-ADServiceAccount noch vorhanden." }
    Write-Host "gMSA $sam entfernt. Aufgeräumt." -ForegroundColor Green
}

# ── Standardlauf: Computer aus 4741-Events in die Gruppe aufnehmen ──────────

function Add-NewComputers {
    Import-Module ActiveDirectory
    $dc = $env:COMPUTERNAME     # lokaler DC: kein Replikations-Lag, das Konto wurde hier angelegt
    $target = if ($GroupName) { $GroupName } else { $DefaultGroup }
    $group = Get-ADGroup -Identity $target -Server $dc

    if ($ComputerSam -like '$(*') {
        # Manueller Start des Tasks (Start-ScheduledTask): der Platzhalter wurde nicht ersetzt -> Selbsttest ohne Log-Suche
        Test-Self -Group $group -Dc $dc
        return
    }

    if ($ComputerSam) {
        if ($ComputerSam -notmatch '^[A-Za-z0-9._$-]{1,20}$') { Write-Log "FEHLER ungültiger Kontoname übergeben: '$ComputerSam'"; exit 1 }
        $names = @($ComputerSam)
    } else {
        # Fallback/Nachholen: Security-Log durchsuchen (auf grossen Logs minutenlang)
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = "Security"
                Id        = 4741
                StartTime = (Get-Date).AddMinutes(-$LookbackMinutes)
            } -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -like "NoMatchingEventsFound*") { $events = @() }
            else { Write-Log "FEHLER Security-Log nicht lesbar: $($_.Exception.Message)"; exit 1 }
        }
        if ($events.Count -eq 0) { Write-Log "Keine 4741-Events in den letzten $LookbackMinutes min (Zielgruppe: $($group.Name))."; return }
        $names = $events | ForEach-Object {
            $xml = [xml]$_.ToXml()
            $xml.Event.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" } | ForEach-Object { $_.'#text' }
        } | Where-Object { $_ } | Select-Object -Unique
    }

    foreach ($sam in $names) {
        try {
            $comp = $null
            for ($i = 0; $i -lt 3 -and -not $comp; $i++) {
                # Get-ADObject statt Get-ADComputer: Event 4741 entsteht auch für gMSAs (kein Computer-Objekt)
                $comp = Get-ADObject -Filter "SamAccountName -eq '$sam'" -Properties MemberOf, objectClass -Server $dc
                if (-not $comp) { Start-Sleep -Seconds 2 }
            }
            if (-not $comp) { Write-Log "SKIP  $sam - Konto nicht (mehr) gefunden"; continue }
            if ($comp.objectClass -ne "computer") { Write-Log "SKIP  $sam - kein Computerkonto (objectClass: $($comp.objectClass))"; continue }
            if ($OuList.Count -gt 0) {
                $inOu = $false
                foreach ($o in $OuList) {
                    if ($comp.DistinguishedName.EndsWith("," + $o, [StringComparison]::OrdinalIgnoreCase)) { $inOu = $true; break }
                }
                if (-not $inOu) {
                    Write-Log "SKIP  $sam - nicht in den OUs '$($OuList -join ' | ')' (liegt in: $(($comp.DistinguishedName -split '(?<!\\),', 2)[1]))"; continue
                }
            }
            if ($comp.MemberOf -contains $group.DistinguishedName) { Write-Log "OK    $sam - bereits Mitglied von $($group.Name)"; continue }
            Add-ADGroupMember -Identity $group -Members $comp.DistinguishedName -Server $dc
            Write-Log "ADD   $sam -> $($group.Name)"
        } catch {
            Write-Log "FEHLER $sam - $($_.Exception.Message)"
        }
    }
}

function Test-Self {
    # Schneller Selbsttest unter dem Task-Konto (kein Durchsuchen des Logs):
    # Gruppe auflösbar, Security-Log lesbar, Schreibrecht auf 'member' (Probe: vorhandenes Mitglied erneut hinzufügen
    # - das ändert nichts; "Zugriff verweigert" wäre ein Fehler, "bereits Mitglied" der erwartete Normalfall).
    param($Group, [string] $Dc)
    try { Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop | Out-Null }
    catch { Write-Log "FEHLER Selbsttest: Security-Log nicht lesbar: $($_.Exception.Message)"; exit 1 }

    foreach ($o in $OuList) {
        if (-not (Get-ADObject -Identity $o -Server $Dc -ErrorAction SilentlyContinue)) {
            Write-Log "FEHLER Selbsttest: OU '$o' nicht gefunden"; exit 1
        }
    }
    $g = Get-ADGroup -Identity $Group.DistinguishedName -Properties member -Server $Dc
    $first = @($g.member) | Select-Object -First 1
    if (-not $first) {
        Write-Log "Selbsttest OK (Gruppe '$($Group.Name)' auflösbar, Security-Log lesbar). Schreibrecht-Probe übersprungen: Gruppe ist leer."
        return
    }
    try {
        Add-ADGroupMember -Identity $Group -Members $first -Server $Dc
        Write-Log "Selbsttest: Probe-Hinzufügen war ohne Fehler (Mitglied war bereits vorhanden/ist unverändert)."
    } catch [UnauthorizedAccessException] {
        Write-Log "FEHLER Selbsttest: Kein Schreibrecht auf 'member' von '$($Group.Name)' für $env:USERNAME ($($_.Exception.Message))"
        exit 1
    } catch {
        $m = "[{0}] {1}" -f $_.Exception.GetType().Name, $_.Exception.Message
        if     ($m -match 'already|bereits|exist') {
            Write-Log "Selbsttest OK (Gruppe auflösbar, Security-Log lesbar, Schreibrecht vorhanden: Server meldet 'bereits Mitglied'). $m"
        } elseif ($m -match 'insufficient|access|denied|zugriff|verweigert|berechtigung') {
            Write-Log "FEHLER Selbsttest: Kein Schreibrecht auf 'member' von '$($Group.Name)' für $env:USERNAME. $m"
            exit 1
        } else {
            Write-Log "Selbsttest UNKLAR beim Schreibtest (weder 'bereits Mitglied' noch Zugriffsfehler erkannt): $m"
        }
        return
    }
    Write-Log "Selbsttest OK (Gruppe auflösbar, Security-Log lesbar, Schreibrecht vorhanden)."
}

# ── Einstieg ─────────────────────────────────────────────────────────────────

if     ($CheckPol)   { if (-not (Test-AuditPolicy)) { exit 1 } }
elseif ($CreateTask) { New-EventTask }
elseif ($RemoveGmsa) { Remove-GmsaSetup }
else                 { Add-NewComputers }
