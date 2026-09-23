# Set-UpnMailAndProxy.ps1
# Migrates UserPrincipalName / mail / proxyAddresses to a new domain (or aligns
# UPN to mail), with a separate preview step and a rollback path.
#
# -Mode selects what the script does. Everything else is one file, run three
# times in sequence:
#
#   1. -Mode CreateInput   (optional) pick candidate users, write an input CSV
#   2. -Mode Plan          read-only: compute what WOULD change, write a plan CSV
#   3. -Mode Apply         apply a plan CSV, write a state CSV (needed for rollback)
#   4. -Mode Restore       undo a state CSV
#
# -Scope (Plan mode) chooses which attributes are touched: Both | UpnOnly | MailOnly
# -UpnMode (Plan mode) chooses how the new UPN is computed:
#     Suffix    (default) - keep the existing UPN local part, swap the domain for -TargetDomain
#     MatchMail            - set the UPN to the user's (post-migration) mail value outright
#
# Examples:
#   .\Set-UpnMailAndProxy.ps1 -Mode CreateInput
#   .\Set-UpnMailAndProxy.ps1 -Mode Plan -InputCsvPath users.csv -TargetDomain contoso.com
#   .\Set-UpnMailAndProxy.ps1 -Mode Plan -InputCsvPath users.csv -Scope UpnOnly -UpnMode MatchMail
#   .\Set-UpnMailAndProxy.ps1 -Mode Apply -PlanCsvPath PLAN_....csv -WhatIf
#   .\Set-UpnMailAndProxy.ps1 -Mode Apply -PlanCsvPath PLAN_....csv
#   .\Set-UpnMailAndProxy.ps1 -Mode Restore -StateCsvPath STATE_....csv

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateSet('CreateInput', 'Plan', 'Apply', 'Restore')][string]$Mode,

    # --- CreateInput ---
    [string]$SearchBase,
    [string]$LdapFilter = '(&(objectCategory=person)(objectClass=user))',
    [string]$OutputCsvPath,

    # --- Plan ---
    [string]$InputCsvPath,
    [ValidateSet('Both', 'UpnOnly', 'MailOnly')][string]$Scope = 'Both',
    [ValidateSet('Suffix', 'MatchMail')][string]$UpnMode = 'Suffix',
    [string]$TargetDomain,
    [switch]$SkipAdWideCollisionCheck,

    # --- Apply / Restore ---
    [string]$PlanCsvPath,
    [string]$StateCsvPath
)

Import-Module ActiveDirectory -ErrorAction Stop

# ============================== Helpers ==============================

function Test-IsBlank {
    param([Parameter(Position = 0)][AllowNull()][string]$Value)
    return [string]::IsNullOrWhiteSpace($Value)
}

function Get-LocalPart {
    param([Parameter(Position = 0)][AllowNull()][string]$Address)
    if (Test-IsBlank $Address) { return $Address }
    if ($Address -match '^(?<local>[^@]+)@') { return $Matches.local }
    return $Address
}

function ConvertTo-ArraySafe {
    # Windows PowerShell 5.1's ConvertFrom-Json turns "[]" into $null, which after
    # @(...) becomes a one-element array containing $null. Strip that out here so
    # every caller gets either a real empty array or an array of real values.
    param([Parameter(Position = 0)][AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @(@($Value) | Where-Object { $null -ne $_ })
}

function Resolve-AdUserIdentity {
    # Accepts a DistinguishedName, ObjectGUID, SamAccountName, UserPrincipalName,
    # or mail address. Get-ADUser -Identity only understands the first three
    # forms, so UPN/mail values are resolved via -Filter instead.
    param(
        [Parameter(Mandatory)][string]$IdentityValue,
        [Parameter(Mandatory)][string[]]$Properties
    )
    try {
        return Get-ADUser -Identity $IdentityValue -Properties $Properties -ErrorAction Stop
    } catch {
        $escaped = $IdentityValue.Replace("'", "''")
        $filter = "userPrincipalName -eq '$escaped' -or mail -eq '$escaped'"
        $found = @(Get-ADUser -Filter $filter -Properties $Properties -ErrorAction Stop)
        if ($found.Count -eq 1) { return $found[0] }
        if ($found.Count -eq 0) { throw "No AD user found for identity '$IdentityValue'." }
        throw "Identity '$IdentityValue' matched $($found.Count) AD users; expected exactly one."
    }
}

function New-ProxyAddressList {
    # Rebuilds proxyAddresses: existing SMTP: becomes smtp:, the previous mail
    # value is kept as a secondary alias, and the new mail value becomes the
    # sole primary (SMTP:). Deduplication compares the address part only,
    # case-insensitively, so a case-only clash between an old alias and the new
    # primary can't silently drop the new primary entry.
    param(
        [AllowNull()][object]$CurrentProxyAddresses,
        [AllowNull()][string]$OldMail,
        [AllowNull()][string]$NewMail
    )
    $current = ConvertTo-ArraySafe $CurrentProxyAddresses
    $byAddress = [ordered]@{}

    function Add-Entry([string]$Entry) {
        if (Test-IsBlank $Entry) { return }
        $address = ($Entry -split ':', 2)[-1]
        $key = $address.ToLowerInvariant()
        if (-not $byAddress.Contains($key)) { $byAddress[$key] = $Entry }
    }

    foreach ($p in $current) {
        if ($p -cmatch '^SMTP:') { Add-Entry ('smtp:' + $p.Substring(5)) } else { Add-Entry $p }
    }
    if (-not (Test-IsBlank $OldMail)) { Add-Entry ('smtp:' + $OldMail) }
    if (-not (Test-IsBlank $NewMail)) { $byAddress[$NewMail.ToLowerInvariant()] = ('SMTP:' + $NewMail) }

    @($byAddress.Values | Sort-Object)
}

function Get-ProxyAddressDiff {
    param([AllowNull()][object]$OldList, [AllowNull()][object]$NewList)
    $old = ConvertTo-ArraySafe $OldList
    $new = ConvertTo-ArraySafe $NewList
    $cmp = Compare-Object -ReferenceObject $old -DifferenceObject $new
    [pscustomobject]@{
        Added   = (@($cmp | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject) -join ',')
        Removed = (@($cmp | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject) -join ',')
    }
}

$adProps = 'mail', 'proxyAddresses', 'userPrincipalName', 'objectGUID', 'samAccountName', 'distinguishedName'

# ============================== CreateInput ==============================

if ($Mode -eq 'CreateInput') {
    $getParams = @{ LDAPFilter = $LdapFilter; Properties = 'mail', 'userPrincipalName', 'displayName' }
    if ($SearchBase) { $getParams.SearchBase = $SearchBase }

    $candidates = Get-ADUser @getParams |
        Where-Object { $_.userPrincipalName -or $_.mail } |
        Select-Object @{ Name = 'Identity'; Expression = { $_.DistinguishedName } }, SamAccountName, DisplayName, UserPrincipalName, mail

    $selected = $candidates | Out-GridView -PassThru -Title 'Select users for migration'
    if (-not $selected) { Write-Host 'No users selected.'; return }

    if (Test-IsBlank $OutputCsvPath) { $OutputCsvPath = "INPUT_$(Get-Date -Format yyyyMMddHHmmss).csv" }
    $selected | Export-Csv $OutputCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host "Input CSV written: $OutputCsvPath"
    return
}

# ============================== Plan ==============================

if ($Mode -eq 'Plan') {
    if (Test-IsBlank $InputCsvPath) { throw 'InputCsvPath is required for -Mode Plan.' }

    $touchUpn = $Scope -in ('Both', 'UpnOnly')
    $touchMail = $Scope -in ('Both', 'MailOnly')

    if ($touchMail -and (Test-IsBlank $TargetDomain)) {
        throw "TargetDomain is required when Scope is '$Scope' (mail is being changed)."
    }
    if ($touchUpn -and $UpnMode -eq 'Suffix' -and (Test-IsBlank $TargetDomain)) {
        throw "TargetDomain is required when UpnMode is 'Suffix'."
    }
    if (-not $touchUpn -and $PSBoundParameters.ContainsKey('UpnMode')) {
        Write-Warning "UpnMode is ignored because Scope='$Scope' does not include UPN changes."
    }

    $rows = Import-Csv $InputCsvPath -Delimiter ';'
    if ($rows.Count -eq 0) { throw "InputCsvPath '$InputCsvPath' contains no rows." }

    $plan = New-Object System.Collections.Generic.List[object]
    $seenUpn = @{}
    $seenMail = @{}

    foreach ($row in $rows) {
        $identityValue = @('Identity', 'DistinguishedName', 'ObjectGUID', 'SamAccountName', 'UserPrincipalName', 'mail') |
            ForEach-Object { $row.$_ } | Where-Object { -not (Test-IsBlank $_) } | Select-Object -First 1

        if (Test-IsBlank $identityValue) {
            $plan.Add([pscustomobject]@{ PlanStatus = 'Error'; Note = 'Row has no usable identity column'; SamAccountName = $null })
            continue
        }

        try {
            $u = Resolve-AdUserIdentity -IdentityValue $identityValue -Properties $adProps
        } catch {
            $plan.Add([pscustomobject]@{ PlanStatus = 'Error'; SamAccountName = $identityValue; Note = $_.Exception.Message })
            continue
        }

        $oldUpn = [string]$u.userPrincipalName
        $oldMail = [string]$u.mail
        $oldProxy = ConvertTo-ArraySafe $u.proxyAddresses

        $newMail = $oldMail
        if ($touchMail -and -not (Test-IsBlank $oldMail)) {
            $newMail = (Get-LocalPart $oldMail) + '@' + $TargetDomain
        }

        $newUpn = $oldUpn
        if ($touchUpn) {
            if ($UpnMode -eq 'Suffix') {
                if (-not (Test-IsBlank $oldUpn)) { $newUpn = (Get-LocalPart $oldUpn) + '@' + $TargetDomain }
            } else {
                $effectiveMail = if ($touchMail) { $newMail } else { $oldMail }
                if (-not (Test-IsBlank $effectiveMail)) { $newUpn = $effectiveMail }
            }
        }

        $newProxy = if ($touchMail) { New-ProxyAddressList $oldProxy $oldMail $newMail } else { $oldProxy }
        $diff = Get-ProxyAddressDiff $oldProxy $newProxy

        $status = 'OK'
        $note = $null

        if ($touchMail -and (Test-IsBlank $oldMail)) {
            $status = 'SkippedNoMail'; $note = 'mail attribute empty'
        } elseif ($touchUpn -and (Test-IsBlank $newUpn)) {
            $status = 'SkippedNoUpn'; $note = 'no UPN could be computed'
        } else {
            if ($touchUpn -and $newUpn -ne $oldUpn) {
                if ($seenUpn.ContainsKey($newUpn)) {
                    $status = 'Collision'; $note = "Duplicate target UPN within batch (also used by $($seenUpn[$newUpn]))"
                } elseif (-not $SkipAdWideCollisionCheck) {
                    $escaped = $newUpn.Replace("'", "''")
                    $clash = Get-ADUser -Filter "userPrincipalName -eq '$escaped'" -ErrorAction SilentlyContinue |
                        Where-Object DistinguishedName -ne $u.DistinguishedName
                    if ($clash) { $status = 'Collision'; $note = "Target UPN already used by existing AD user $($clash.SamAccountName)" }
                }
            }
            if ($status -eq 'OK' -and $touchMail -and $newMail -ne $oldMail) {
                if ($seenMail.ContainsKey($newMail)) {
                    $status = 'Collision'; $note = "Duplicate target mail within batch (also used by $($seenMail[$newMail]))"
                } elseif (-not $SkipAdWideCollisionCheck) {
                    $escaped = $newMail.Replace("'", "''")
                    $clash = Get-ADUser -Filter "mail -eq '$escaped'" -ErrorAction SilentlyContinue |
                        Where-Object DistinguishedName -ne $u.DistinguishedName
                    if ($clash) { $status = 'Collision'; $note = "Target mail already used by existing AD user $($clash.SamAccountName)" }
                }
            }
        }

        if ($status -eq 'OK') {
            if ($touchUpn) { $seenUpn[$newUpn] = $u.SamAccountName }
            if ($touchMail) { $seenMail[$newMail] = $u.SamAccountName }
        }

        $plan.Add([pscustomobject]@{
            PlanStatus        = $status
            Note              = $note
            SamAccountName    = $u.SamAccountName
            DistinguishedName = $u.DistinguishedName
            ObjectGUID        = [string]$u.ObjectGUID
            OldUPN            = $oldUpn
            NewUPN            = $newUpn
            OldMail           = $oldMail
            NewMail           = $newMail
            OldProxyAddresses = ($oldProxy | ConvertTo-Json -Compress)
            NewProxyAddresses = ($newProxy | ConvertTo-Json -Compress)
            ProxyAdded        = $diff.Added
            ProxyRemoved      = $diff.Removed
        })
    }

    if (Test-IsBlank $PlanCsvPath) { $PlanCsvPath = "PLAN_$(Get-Date -Format yyyyMMddHHmmss).csv" }
    $plan | Export-Csv $PlanCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host "Plan written: $PlanCsvPath"
    $plan | Group-Object PlanStatus | Select-Object Name, Count | Format-Table -AutoSize
    $plan
    return
}

# ============================== Apply ==============================

if ($Mode -eq 'Apply') {
    if (Test-IsBlank $PlanCsvPath) { throw 'PlanCsvPath is required for -Mode Apply.' }

    $plan = Import-Csv $PlanCsvPath -Delimiter ';'
    $state = New-Object System.Collections.Generic.List[object]

    foreach ($row in $plan) {
        if ($row.PlanStatus -ne 'OK') {
            [pscustomobject]@{ Result = 'Skipped'; SamAccountName = $row.SamAccountName; Note = "PlanStatus=$($row.PlanStatus)" }
            continue
        }

        try {
            $u = Get-ADUser -Identity $row.DistinguishedName -Properties $adProps -ErrorAction Stop
        } catch {
            $state.Add([pscustomobject]@{
                SamAccountName = $row.SamAccountName; DistinguishedName = $row.DistinguishedName; ObjectGUID = $row.ObjectGUID
                OldUPN = $row.OldUPN; NewUPN = $row.NewUPN; UpnStatus = 'Error'
                OldMail = $row.OldMail; NewMail = $row.NewMail
                OldProxyAddresses = $row.OldProxyAddresses; NewProxyAddresses = $row.NewProxyAddresses; MailStatus = 'Error'
                Note = 'Object not found at apply time'
            })
            [pscustomobject]@{ Result = 'Error'; SamAccountName = $row.SamAccountName; Note = 'Object not found at apply time' }
            continue
        }

        if ([string]$u.userPrincipalName -ne $row.OldUPN -or [string]$u.mail -ne $row.OldMail) {
            $state.Add([pscustomobject]@{
                SamAccountName = $row.SamAccountName; DistinguishedName = $row.DistinguishedName; ObjectGUID = $row.ObjectGUID
                OldUPN = $row.OldUPN; NewUPN = $row.NewUPN; UpnStatus = 'SkippedStale'
                OldMail = $row.OldMail; NewMail = $row.NewMail
                OldProxyAddresses = $row.OldProxyAddresses; NewProxyAddresses = $row.NewProxyAddresses; MailStatus = 'SkippedStale'
                Note = 'Live AD values no longer match the plan; re-run -Mode Plan'
            })
            [pscustomobject]@{ Result = 'SkippedStale'; SamAccountName = $row.SamAccountName }
            continue
        }

        $upnStatus = 'Unchanged'
        $mailStatus = 'Unchanged'
        $upnNote = $null
        $mailNote = $null

        if ($row.NewUPN -ne $row.OldUPN) {
            if ($PSCmdlet.ShouldProcess($row.SamAccountName, "Set UserPrincipalName to '$($row.NewUPN)'")) {
                try {
                    Set-ADUser -Identity $u.DistinguishedName -UserPrincipalName $row.NewUPN -ErrorAction Stop
                    $upnStatus = 'Changed'
                } catch {
                    $upnStatus = 'Error'; $upnNote = $_.Exception.Message
                }
            } else {
                $upnStatus = 'WhatIf'
            }
        }

        if ($row.NewMail -ne $row.OldMail -or $row.NewProxyAddresses -ne $row.OldProxyAddresses) {
            $newProxy = ConvertTo-ArraySafe (@($row.NewProxyAddresses | ConvertFrom-Json))
            if ($PSCmdlet.ShouldProcess($row.SamAccountName, "Set mail to '$($row.NewMail)' and update proxyAddresses")) {
                try {
                    if (Test-IsBlank $row.NewMail) { Set-ADUser -Identity $u.DistinguishedName -Clear mail -ErrorAction Stop }
                    else { Set-ADUser -Identity $u.DistinguishedName -Replace @{ mail = $row.NewMail } -ErrorAction Stop }

                    if ($newProxy.Count -eq 0) { Set-ADUser -Identity $u.DistinguishedName -Clear proxyAddresses -ErrorAction Stop }
                    else { Set-ADUser -Identity $u.DistinguishedName -Replace @{ proxyAddresses = $newProxy } -ErrorAction Stop }

                    $mailStatus = 'Changed'
                } catch {
                    $mailStatus = 'Error'; $mailNote = $_.Exception.Message
                }
            } else {
                $mailStatus = 'WhatIf'
            }
        }

        $state.Add([pscustomobject]@{
            SamAccountName    = $row.SamAccountName
            DistinguishedName = $row.DistinguishedName
            ObjectGUID        = $row.ObjectGUID
            OldUPN            = $row.OldUPN
            NewUPN            = $row.NewUPN
            UpnStatus         = $upnStatus
            OldMail           = $row.OldMail
            NewMail           = $row.NewMail
            OldProxyAddresses = $row.OldProxyAddresses
            NewProxyAddresses = $row.NewProxyAddresses
            MailStatus        = $mailStatus
            Note              = @($upnNote, $mailNote | Where-Object { $_ }) -join ' | '
        })

        [pscustomobject]@{ Result = "Upn=$upnStatus,Mail=$mailStatus"; SamAccountName = $row.SamAccountName }
    }

    if (Test-IsBlank $StateCsvPath) { $StateCsvPath = "STATE_$(Get-Date -Format yyyyMMddHHmmss).csv" }
    $state | Export-Csv $StateCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host "State written: $StateCsvPath (needed for -Mode Restore)"
    return
}

# ============================== Restore ==============================

if ($Mode -eq 'Restore') {
    if (Test-IsBlank $StateCsvPath) { throw 'StateCsvPath is required for -Mode Restore.' }

    $rows = Import-Csv $StateCsvPath -Delimiter ';'

    foreach ($row in $rows) {
        if ($row.UpnStatus -ne 'Changed' -and $row.MailStatus -ne 'Changed') {
            [pscustomobject]@{ Result = 'Skipped'; SamAccountName = $row.SamAccountName; Note = 'Nothing to roll back' }
            continue
        }

        try {
            $u = if (-not (Test-IsBlank $row.ObjectGUID)) { Get-ADUser -Identity $row.ObjectGUID -Properties $adProps -ErrorAction Stop }
            else { Get-ADUser -Identity $row.DistinguishedName -Properties $adProps -ErrorAction Stop }
        } catch {
            [pscustomobject]@{ Result = 'Error'; SamAccountName = $row.SamAccountName; Note = 'Object not found' }
            continue
        }

        if ($row.UpnStatus -eq 'Changed') {
            if ([string]$u.userPrincipalName -ne $row.NewUPN) {
                [pscustomobject]@{ Result = 'SkippedStale'; SamAccountName = $u.SamAccountName; Note = 'Current UPN no longer matches the applied value; not rolling back to avoid clobbering a later change' }
            } elseif ($PSCmdlet.ShouldProcess($u.SamAccountName, "Restore UserPrincipalName to '$($row.OldUPN)'")) {
                try {
                    if (Test-IsBlank $row.OldUPN) { Set-ADUser -Identity $u.DistinguishedName -Clear userPrincipalName -ErrorAction Stop }
                    else { Set-ADUser -Identity $u.DistinguishedName -UserPrincipalName $row.OldUPN -ErrorAction Stop }
                    [pscustomobject]@{ Result = 'UpnRolledBack'; SamAccountName = $u.SamAccountName }
                } catch {
                    [pscustomobject]@{ Result = 'Error'; SamAccountName = $u.SamAccountName; Note = $_.Exception.Message }
                }
            }
        }

        if ($row.MailStatus -eq 'Changed') {
            $expectedProxy = ConvertTo-ArraySafe (@($row.NewProxyAddresses | ConvertFrom-Json))
            $currentProxy = ConvertTo-ArraySafe $u.proxyAddresses
            $proxyMatches = (Compare-Object $expectedProxy $currentProxy).Count -eq 0

            if ([string]$u.mail -ne $row.NewMail -or -not $proxyMatches) {
                [pscustomobject]@{ Result = 'SkippedStale'; SamAccountName = $u.SamAccountName; Note = 'Current mail/proxyAddresses no longer match the applied value; not rolling back to avoid clobbering a later change' }
            } elseif ($PSCmdlet.ShouldProcess($u.SamAccountName, "Restore mail to '$($row.OldMail)' and proxyAddresses")) {
                try {
                    $oldProxy = ConvertTo-ArraySafe (@($row.OldProxyAddresses | ConvertFrom-Json))
                    if (Test-IsBlank $row.OldMail) { Set-ADUser -Identity $u.DistinguishedName -Clear mail -ErrorAction Stop }
                    else { Set-ADUser -Identity $u.DistinguishedName -Replace @{ mail = $row.OldMail } -ErrorAction Stop }

                    if ($oldProxy.Count -eq 0) { Set-ADUser -Identity $u.DistinguishedName -Clear proxyAddresses -ErrorAction Stop }
                    else { Set-ADUser -Identity $u.DistinguishedName -Replace @{ proxyAddresses = $oldProxy } -ErrorAction Stop }

                    [pscustomobject]@{ Result = 'MailRolledBack'; SamAccountName = $u.SamAccountName }
                } catch {
                    [pscustomobject]@{ Result = 'Error'; SamAccountName = $u.SamAccountName; Note = $_.Exception.Message }
                }
            }
        }
    }
    return
}
