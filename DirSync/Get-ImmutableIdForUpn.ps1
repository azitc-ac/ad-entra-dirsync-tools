# Requires: RSAT-AD-PowerShell (ActiveDirectory Modul)
# PowerShell 5.1 kompatibel – keine ternären Operatoren, keine Spezialsyntax

[CmdletBinding()]
param(
    # Liste von OU-DNs, z.B. "OU=Berlin,DC=contoso,DC=com"
    [string[]]$OU,

    # Öffnet einen WinForms-Dialog zur Auswahl mehrerer OUs (wenn -OU nicht angegeben)
    [switch]$PickOU,

    # Ausgabe-CSV; wenn nicht gesetzt, wird ein datierter Name verwendet
    [string]$OutFile,

    # Optional: expliziter Domain Controller
    [string]$Server,

    # Erzwingt Verwendung von mS-DS-ConsistencyGuid als Source Anchor (für dieses Skript/Run)
    [switch]$ForceConsistencyGuid,

    # Erzwingt Verwendung von objectGUID als Source Anchor (für dieses Skript/Run)
    [switch]$ForceObjectGuid,

    # Exportiert zusätzliche Spalten (ConsistencyGuid, ObjectGuid)
    [switch]$IncludeAnchorDetails
)

function Test-ModuleLoaded {
    param([string]$Name)
    $m = Get-Module -Name $Name
    if ($null -eq $m) { return $false } else { return $true }
}

function Ensure-ADModule {
    if (-not (Test-ModuleLoaded -Name 'ActiveDirectory')) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
        } catch {
            Write-Error "ActiveDirectory-Modul konnte nicht geladen werden. RSAT/AD-Tools installieren."
            throw
        }
    }
}

function Get-DefaultNC {
    param([string]$Server)
    try {
        if ([string]::IsNullOrWhiteSpace($Server)) {
            $root = Get-ADRootDSE
        } else {
            $root = Get-ADRootDSE -Server $Server
        }
        return $root.defaultNamingContext
    } catch {
        Write-Error "Konnte defaultNamingContext nicht ermitteln: $($_.Exception.Message)"
        throw
    }
}

function Get-AllOUs {
    param(
        [string]$SearchBase,
        [string]$Server
    )
    $params = @{ Filter = '*' ; SearchBase = $SearchBase ; SearchScope = 'Subtree' ; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $params['Server'] = $Server }
    Get-ADOrganizationalUnit @params | Select-Object Name, DistinguishedName
}

# --- Stabile Sortierung für ListView (PS 5.1-kompatibel) ---
if (-not ('ListViewColumnSorter' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @"
using System;
using System.Collections;
using System.Windows.Forms;

public class ListViewColumnSorter : IComparer
{
    public int Column { get; set; }
    public SortOrder Order { get; set; }

    public ListViewColumnSorter()
    {
        this.Column = 0;
        this.Order = SortOrder.Ascending;
    }

    public int Compare(object x, object y)
    {
        var a = x as ListViewItem;
        var b = y as ListViewItem;

        string sx = (a == null || a.SubItems.Count <= Column || a.SubItems[Column].Text == null)
                    ? string.Empty : a.SubItems[Column].Text;
        string sy = (b == null || b.SubItems.Count <= Column || b.SubItems[Column].Text == null)
                    ? string.Empty : b.SubItems[Column].Text;

        int r = StringComparer.CurrentCultureIgnoreCase.Compare(sx, sy);
        return (this.Order == SortOrder.Descending) ? -r : r;
    }
}
"@ -ErrorAction Stop
}

function Show-OUSelectionDialog {
    param([System.Object[]]$OUList) # PSCustomObjects mit Name, DistinguishedName

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "OUs auswählen"
    $form.StartPosition = 'CenterScreen'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 11)  # 11pt
    $form.MinimumSize = New-Object System.Drawing.Size(1200, 800)
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Filter (Name oder DN):"
    $lbl.AutoSize = $true
    $lbl.Top  = 12
    $lbl.Left = 12
    $lbl.Anchor = 'Top,Left'

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.AutoSize = $true
    $txtFilter.Top  = 12
    $txtFilter.Left = 350
    $txtFilter.Width = $form.ClientSize.Width - 212
    $txtFilter.Anchor = 'Top,Left,Right'

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Top  = 46
    $lv.Left = 12
    $lv.Width  = $form.ClientSize.Width  - 24
    $lv.Height = $form.ClientSize.Height - 140
    $lv.Anchor = 'Top,Left,Right,Bottom'
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.CheckBoxes = $true
    $lv.GridLines = $true
    $lv.HideSelection = $false
    $lv.Font = New-Object System.Drawing.Font("Segoe UI", 11)  # 11pt ListView
    [void]$lv.Columns.Add("Name", 300)
    [void]$lv.Columns.Add("Distinguished Name", 800)

    $lv.Sorting = [System.Windows.Forms.SortOrder]::None
    $sorter = New-Object ListViewColumnSorter
    $sorter.Column = 0
    $sorter.Order  = [System.Windows.Forms.SortOrder]::Ascending
    $lv.ListViewItemSorter = $sorter

    $lv.add_ColumnClick({
        param($sender, $e)
        if ($sorter.Column -eq $e.Column) {
            if ($sorter.Order -eq [System.Windows.Forms.SortOrder]::Ascending) {
                $sorter.Order = [System.Windows.Forms.SortOrder]::Descending
            } else {
                $sorter.Order = [System.Windows.Forms.SortOrder]::Ascending
            }
        } else {
            $sorter.Column = $e.Column
            $sorter.Order  = [System.Windows.Forms.SortOrder]::Ascending
        }
        $sender.Sort()
    })

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Alle markieren"
    $btnAll.Top  = $form.ClientSize.Height - 78
    $btnAll.Left = 12
    $btnAll.Width = 200
    $btnAll.Height = 44
    $btnAll.Anchor = 'Bottom,Left'

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = "Keine"
    $btnNone.Top  = $btnAll.Top
    $btnNone.Left = 220
    $btnNone.Width = 140
    $btnNone.Height = 44
    $btnNone.Anchor = 'Bottom,Left'

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Top  = $btnAll.Top
    $btnOK.Left = $form.ClientSize.Width - 220
    $btnOK.Width = 90
    $btnOK.Height = 44
    $btnOK.Anchor = 'Bottom,Right'
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Abbrechen"
    $btnCancel.Top  = $btnAll.Top
    $btnCancel.Left = $form.ClientSize.Width - 120
    $btnCancel.Width = 100
    $btnCancel.Height = 44
    $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($lbl, $txtFilter, $lv, $btnAll, $btnNone, $btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    $form.add_ClientSizeChanged({
        $txtFilter.Width = $form.ClientSize.Width - 212
        $lv.Width  = $form.ClientSize.Width  - 24
        $lv.Height = $form.ClientSize.Height - 140
        $btnOK.Left     = $form.ClientSize.Width - 220
        $btnCancel.Left = $form.ClientSize.Width - 120
        $btnAll.Top     = $form.ClientSize.Height - 78
        $btnNone.Top    = $btnAll.Top
        $btnOK.Top      = $btnAll.Top
        $btnCancel.Top  = $btnAll.Top
        $lv.Columns[0].Width = 300
        $lv.Columns[1].Width = $lv.ClientSize.Width - 320
    })

    $allRows = @()
    foreach ($ou in $OUList) {
        $allRows += [PSCustomObject]@{
            Name = $ou.Name
            DN   = $ou.DistinguishedName
        }
    }

    $fillList = {
        param($needle)
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            $n = $needle
            foreach ($row in ($allRows | Sort-Object Name)) {
                $add = $true
                if (-not [string]::IsNullOrWhiteSpace($n)) {
                    $f = $n.ToLower()
                    if ($row.Name.ToLower().IndexOf($f) -lt 0 -and $row.DN.ToLower().IndexOf($f) -lt 0) {
                        $add = $false
                    }
                }
                if ($add) {
                    $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
                    [void]$item.SubItems.Add($row.DN)
                    [void]$lv.Items.Add($item)
                }
            }
        } finally { $lv.EndUpdate() }
        $lv.Columns[0].Width = 300
        $lv.Columns[1].Width = $lv.ClientSize.Width - 320
    }

    $txtFilter.add_TextChanged({ & $fillList $txtFilter.Text })
    $btnAll.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $true } })
    $btnNone.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $false } })

    & $fillList ""
    $dialogResult = $form.ShowDialog()
    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) { return @() }

    $selected = @()
    foreach ($it in $lv.Items) {
        if ($it.Checked) {
            $selected += $it.SubItems[1].Text
        }
    }
    return $selected
}

function Get-UsersFromOU {
    param(
        [string]$SearchBase,
        [string]$Server
    )
    $params = @{
        Filter = '*'
        SearchBase = $SearchBase
        SearchScope = 'Subtree'
        Properties = @('objectGUID','mS-DS-ConsistencyGuid','userPrincipalName','mail','samAccountName','distinguishedName')
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $params['Server'] = $Server }
    try {
        Get-ADUser @params
    } catch {
        Write-Warning "OU konnte nicht gelesen werden ($SearchBase): $($_.Exception.Message)"
        @()
    }
}

function Get-AnchorBytesAndType {
    param(
        [Microsoft.ActiveDirectory.Management.ADUser]$AdUser,
        [switch]$ForceConsistencyGuid,
        [switch]$ForceObjectGuid
    )

    $bytes = $null
    $typeName = $null

    if ($ForceConsistencyGuid.IsPresent) {
        if ($AdUser.'mS-DS-ConsistencyGuid') {
            $cg = $AdUser.'mS-DS-ConsistencyGuid'
            if ($cg -is [byte[]]) {
                $bytes = $cg
            } elseif ($cg -is [Guid]) {
                $bytes = $cg.ToByteArray()
            } else {
                throw "mS-DS-ConsistencyGuid hat unerwarteten Typ: $($cg.GetType().FullName)"
            }
            $typeName = 'mS-DS-ConsistencyGuid'
        } else {
            throw "mS-DS-ConsistencyGuid ist leer, aber -ForceConsistencyGuid wurde angegeben."
        }
    } elseif ($ForceObjectGuid.IsPresent) {
        if ($AdUser.objectGUID) {
            $bytes = $AdUser.objectGUID.ToByteArray()
            $typeName = 'objectGUID'
        } else {
            throw "objectGUID fehlt."
        }
    } else {
        # Auto-Erkennung: bevorzugt mS-DS-ConsistencyGuid, sonst objectGUID
        if ($AdUser.'mS-DS-ConsistencyGuid') {
            $cgAuto = $AdUser.'mS-DS-ConsistencyGuid'
            if ($cgAuto -is [byte[]]) {
                $bytes = $cgAuto
            } elseif ($cgAuto -is [Guid]) {
                $bytes = $cgAuto.ToByteArray()
            } else {
                throw "mS-DS-ConsistencyGuid hat unerwarteten Typ: $($cgAuto.GetType().FullName)"
            }
            $typeName = 'mS-DS-ConsistencyGuid'
        } elseif ($AdUser.objectGUID) {
            $bytes = $AdUser.objectGUID.ToByteArray()
            $typeName = 'objectGUID'
        } else {
            throw "Weder mS-DS-ConsistencyGuid noch objectGUID verfügbar."
        }
    }

    # Einheitlicher Rückgabewert (stark typisiert)
    return [PSCustomObject]@{
        Bytes  = [byte[]]$bytes
        Anchor = $typeName
    }
}

# --- Main ---
try {
    Ensure-ADModule

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $cleandatetime = Get-Date -UFormat "%Y-%m-%d_%H-%M-%S"
        $OutFile = "UPNs-and-immutableID_$cleandatetime.csv"
    }

    $ouDNs = @()
    if ($OU -and $OU.Count -gt 0) {
        $ouDNs = $OU
    } else {
        if (-not $PickOU.IsPresent) { $PickOU = $true }
        if ($PickOU) {
            $defaultNC = Get-DefaultNC -Server $Server
            $ouList = Get-AllOUs -SearchBase $defaultNC -Server $Server
            if ($null -eq $ouList -or $ouList.Count -eq 0) {
                Write-Error "Keine OUs gefunden."
                exit 1
            }
            $ouDNs = Show-OUSelectionDialog -OUList $ouList
        }
    }

    if ($null -eq $ouDNs -or $ouDNs.Count -eq 0) {
        Write-Warning "Keine OUs ausgewählt/angegeben. Abbruch."
        exit 0
    }

    Write-Host "Verarbeite $($ouDNs.Count) OU(s) rekursiv..." -ForegroundColor Cyan

    $results = New-Object System.Collections.Generic.List[object]
    $totalUsers = 0
    $ouIndex = 0

    # Globales Ergebnis der Auto-Erkennung (für Write-Host)
    $globalAnchor = $null
    $mixedAnchorDetected = $false

    foreach ($ouDN in $ouDNs) {
        $ouIndex = $ouIndex + 1
        Write-Progress -Activity "OU wird gelesen" -Status "$ouIndex / $($ouDNs.Count)" -CurrentOperation $ouDN -PercentComplete (($ouIndex/$ouDNs.Count*100))

        $users = Get-UsersFromOU -SearchBase $ouDN -Server $Server
        if ($null -ne $users) {
            foreach ($u in $users) {
                # Anchor-Ermittlung
                $anchorInfo = $null
                $bytes = $null
                $anchorType = $null
                try {
                    $anchorInfo = Get-AnchorBytesAndType -AdUser $u -ForceConsistencyGuid:$ForceConsistencyGuid -ForceObjectGuid:$ForceObjectGuid
                    if ($anchorInfo -ne $null) {
                        $bytes = $anchorInfo.Bytes
                        $anchorType = $anchorInfo.Anchor
                    }
                    # Globalen Anchor festhalten (einmalig) und Änderungen erkennen
                    if ($globalAnchor -eq $null -and -not [string]::IsNullOrWhiteSpace($anchorType)) {
                        $globalAnchor = $anchorType
                    } elseif ($globalAnchor -ne $null -and -not [string]::IsNullOrWhiteSpace($anchorType) -and $globalAnchor -ne $anchorType) {
                        if (-not $mixedAnchorDetected) {
                            Write-Warning "Gemischte Source-Anchors erkannt: Bisher '$globalAnchor', jetzt '$anchorType'. Details in CSV (Spalte 'SourceAnchorUsed')."
                            $mixedAnchorDetected = $true
                        }
                    }
                } catch {
                    Write-Warning "Anchor konnte nicht ermittelt werden für $($u.SamAccountName): $($_.Exception.Message)"
                }

                # Base64 erstellen (sicher mit byte[])
                $immutable = $null
                if ($bytes -ne $null) {
                    $immutable = [System.Convert]::ToBase64String([byte[]]$bytes)
                }

                # OU-Pfad aus DN extrahieren (alles ab erster OU-Komponente)
                $ouPath = $null
                if ($u.DistinguishedName -and $u.DistinguishedName -match ',(OU=.+)$') {
                    $ouPath = $Matches[1]
                }

                # CSV-Zeile (immer inkl. SourceAnchorUsed)
                if ($IncludeAnchorDetails) {
                    # Roh-GUIDs optional mit exportieren
                    $consistencyGuidRaw = $null
                    if ($u.'mS-DS-ConsistencyGuid') {
                        $cgVal = $u.'mS-DS-ConsistencyGuid'
                        if ($cgVal -is [Guid]) {
                            $consistencyGuidRaw = $cgVal.ToString()
                        } elseif ($cgVal -is [byte[]]) {
                            $g = New-Object Guid ($cgVal)
                            $consistencyGuidRaw = $g.ToString()
                        } else {
                            $consistencyGuidRaw = $cgVal.ToString()
                        }
                    }
                    $objectGuidRaw = $null
                    if ($u.objectGUID) { $objectGuidRaw = $u.objectGUID.ToString() }

                    $results.Add([PSCustomObject]@{
                        UserPrincipalName = $u.UserPrincipalName
                        immutableID       = $immutable
                        Mail              = $u.Mail
                        SamAccountName    = $u.SamAccountName
                        DistinguishedName = $u.DistinguishedName
                        OU                = $ouPath
                        SourceAnchorUsed  = $anchorType
                        ConsistencyGuid   = $consistencyGuidRaw
                        ObjectGuid        = $objectGuidRaw
                    }) | Out-Null
                } else {
                    $results.Add([PSCustomObject]@{
                        UserPrincipalName = $u.UserPrincipalName
                        immutableID       = $immutable
                        Mail              = $u.Mail
                        SamAccountName    = $u.SamAccountName
                        DistinguishedName = $u.DistinguishedName
                        OU                = $ouPath
                        SourceAnchorUsed  = $anchorType
                    }) | Out-Null
                }

                $totalUsers = $totalUsers + 1
            }
        }
    }
    Write-Progress -Activity "OU wird gelesen" -Completed

    if ($results.Count -eq 0) {
        Write-Warning "Keine Benutzer gefunden."
        exit 0
    }

    # Ausgabe der Auto-Erkennung (einmalig)
    if ($ForceConsistencyGuid.IsPresent) {
        Write-Host "Source Anchor (erzwungen): mS-DS-ConsistencyGuid" -ForegroundColor Yellow
    } elseif ($ForceObjectGuid.IsPresent) {
        Write-Host "Source Anchor (erzwungen): objectGUID" -ForegroundColor Yellow
    } else {
        if ($globalAnchor -ne $null) {
            Write-Host ("Source Anchor (auto): {0}" -f $globalAnchor) -ForegroundColor Yellow
        } else {
            Write-Warning "Source Anchor konnte nicht automatisch ermittelt werden (keine nutzbaren Benutzerwerte gefunden)."
        }
        if ($mixedAnchorDetected) {
            Write-Warning "Hinweis: Es wurden gemischte Anchors festgestellt. Prüfe die CSV-Spalte 'SourceAnchorUsed'."
        }
    }

    # Export (UTF-8, kulturabhängiges Trennzeichen)
    cd $PSScriptRoot
    $results | Sort-Object UserPrincipalName | Export-Csv -Path $OutFile -NoTypeInformation -UseCulture -Encoding UTF8

    Write-Host "Fertig. $totalUsers Benutzer exportiert nach: $OutFile" -ForegroundColor Green

} catch {
    Write-Error "Fehler: $($_.Exception.Message)"
    exit 1
}