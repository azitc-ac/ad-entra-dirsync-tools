#Requires -Modules ActiveDirectory
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Data model
$script:leftItems         = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:rightItems        = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:originalRightSAMs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$script:fnNewUserEntry = {
    param([string]$Raw, [string]$SamAccountName = $null, $ADUser = $null, [bool]$IsFound = $false, [string]$SourceColumn = "Input")
    $display = if ($IsFound -and $ADUser) { "$SamAccountName  ($($ADUser.Name))" } else { $Raw }
    [PSCustomObject]@{
        DisplayText    = $display
        SamAccountName = $SamAccountName
        ADUser         = $ADUser
        IsFound        = $IsFound
        Raw            = $Raw
        SourceColumn   = $SourceColumn
    }
}

$script:fnResolve = {
    param([string]$sam, [string]$SourceColumn = "Input")
    $sam = $sam.Trim()
    if (-not $sam) { return $null }
    $adUser = $null
    try {
        $adUser = Get-ADUser -Identity $sam -Properties Name -ErrorAction Stop
    } catch {
        try {
            $filter = "SamAccountName -eq '$sam' -or UserPrincipalName -eq '$sam' -or mail -eq '$sam'"
            $adUser = Get-ADUser -Filter $filter -Properties Name -ErrorAction Stop | Select-Object -First 1
        } catch {}
    }
    if ($adUser) {
        & $script:fnNewUserEntry -Raw $sam -SamAccountName $adUser.SamAccountName -ADUser $adUser -IsFound $true -SourceColumn $SourceColumn
    } else {
        & $script:fnNewUserEntry -Raw $sam -IsFound $false -SourceColumn $SourceColumn
    }
}

$script:fnItemKey = { param($item); if ($item.SamAccountName) { $item.SamAccountName } else { $item.Raw } }

$script:fnRefresh = {
    param($lb, $list)
    $lb.BeginUpdate()
    $lb.Items.Clear()
    foreach ($item in $list) { [void]$lb.Items.Add($item) }
    $lb.EndUpdate()
}
#endregion

#region Form
$form = New-Object System.Windows.Forms.Form
$form.Text          = "AD Gruppenmitglieder verwalten"
$form.Size          = New-Object System.Drawing.Size(860, 660)
$form.MinimumSize   = New-Object System.Drawing.Size(660, 500)
$form.StartPosition = "CenterScreen"
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Padding       = New-Object System.Windows.Forms.Padding(0)

$stripTop = New-Object System.Windows.Forms.Panel
$stripTop.Dock      = "Top"
$stripTop.Height    = 48
$stripTop.BackColor = [System.Drawing.SystemColors]::Control
$stripTop.Padding   = New-Object System.Windows.Forms.Padding(10, 10, 10, 6)

$lblGroup = New-Object System.Windows.Forms.Label
$lblGroup.Text      = "Zielgruppe (AD-Name):"
$lblGroup.AutoSize  = $true
$lblGroup.Location  = New-Object System.Drawing.Point(10, 15)

$txtGroup = New-Object System.Windows.Forms.TextBox
$txtGroup.Location  = New-Object System.Drawing.Point(168, 12)
$txtGroup.Width     = 300
$txtGroup.Anchor    = "Left,Top"

$btnPickGroup = New-Object System.Windows.Forms.Button
$btnPickGroup.Text     = "..."
$btnPickGroup.Location = New-Object System.Drawing.Point(476, 10)
$btnPickGroup.Size     = New-Object System.Drawing.Size(30, 26)
$btnPickGroup.Font     = New-Object System.Drawing.Font("Segoe UI", 8)

$btnLoadGroup = New-Object System.Windows.Forms.Button
$btnLoadGroup.Text     = "Gruppe einlesen"
$btnLoadGroup.Location = New-Object System.Drawing.Point(514, 10)
$btnLoadGroup.Size     = New-Object System.Drawing.Size(120, 26)

$stripTop.Controls.AddRange(@($lblGroup, $txtGroup, $btnPickGroup, $btnLoadGroup))

$stripBottom = New-Object System.Windows.Forms.Panel
$stripBottom.Dock       = "Bottom"
$stripBottom.Height     = 50
$stripBottom.BackColor  = [System.Drawing.SystemColors]::Control
$stripBottom.Padding    = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

$btnLoadCsv = New-Object System.Windows.Forms.Button
$btnLoadCsv.Text     = "CSV laden"
$btnLoadCsv.Size     = New-Object System.Drawing.Size(100, 28)
$btnLoadCsv.Location = New-Object System.Drawing.Point(10, 10)

$btnManual = New-Object System.Windows.Forms.Button
$btnManual.Text     = "Manuell hinzufügen..."
$btnManual.Size     = New-Object System.Drawing.Size(145, 28)
$btnManual.Location = New-Object System.Drawing.Point(118, 10)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text     = "Entfernen"
$btnRemove.Size     = New-Object System.Drawing.Size(90, 28)
$btnRemove.Location = New-Object System.Drawing.Point(271, 10)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text   = "Speichern"
$btnSave.Size   = New-Object System.Drawing.Size(100, 28)
$btnSave.Anchor = "Right,Bottom"

$stripBottom.Controls.AddRange(@($btnLoadCsv, $btnManual, $btnRemove, $btnSave))
$stripBottom.Add_Resize({
    $btnSave.Location = New-Object System.Drawing.Point(
        ($stripBottom.ClientSize.Width - $btnSave.Width - 10), 10)
})

$separator = New-Object System.Windows.Forms.Panel
$separator.Dock      = "Bottom"
$separator.Height    = 1
$separator.BackColor = [System.Drawing.SystemColors]::ControlDark

$tableMain = New-Object System.Windows.Forms.TableLayoutPanel
$tableMain.Dock        = "Fill"
$tableMain.ColumnCount = 3
$tableMain.RowCount    = 2
$tableMain.Padding     = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$tableMain.ColumnStyles.Clear()
[void]$tableMain.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 46)))
[void]$tableMain.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 116)))
[void]$tableMain.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 54)))
$tableMain.RowStyles.Clear()
[void]$tableMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$tableMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$lblLeft = New-Object System.Windows.Forms.Label
$lblLeft.Text      = "Hinzuzufügende Benutzer"
$lblLeft.Dock      = "Fill"
$lblLeft.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblLeft.TextAlign = "MiddleLeft"

$lblRight = New-Object System.Windows.Forms.Label
$lblRight.Text      = "Aktuelle Gruppenmitglieder"
$lblRight.Dock      = "Fill"
$lblRight.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblRight.TextAlign = "MiddleLeft"

$tableMain.Controls.Add($lblLeft,  0, 0)
$tableMain.Controls.Add($lblRight, 2, 0)

$lbLeft = New-Object System.Windows.Forms.ListBox
$lbLeft.Dock                = "Fill"
$lbLeft.SelectionMode       = "MultiExtended"
$lbLeft.DrawMode            = "OwnerDrawFixed"
$lbLeft.ItemHeight          = 20
$lbLeft.ScrollAlwaysVisible = $true
$lbLeft.IntegralHeight      = $false
$lbLeft.BorderStyle         = "FixedSingle"

$lbRight = New-Object System.Windows.Forms.ListBox
$lbRight.Dock                = "Fill"
$lbRight.SelectionMode       = "MultiExtended"
$lbRight.DrawMode            = "OwnerDrawFixed"
$lbRight.ItemHeight          = 20
$lbRight.ScrollAlwaysVisible = $true
$lbRight.IntegralHeight      = $false
$lbRight.BorderStyle         = "FixedSingle"

$panelArrows = New-Object System.Windows.Forms.FlowLayoutPanel
$panelArrows.Dock          = "Fill"
$panelArrows.FlowDirection = "TopDown"
$panelArrows.WrapContents  = $false
$panelArrows.AutoSize      = $false

$btnMvRight = New-Object System.Windows.Forms.Button
$btnMvRight.Text   = ">"
$btnMvRight.Size   = New-Object System.Drawing.Size(76, 28)
$btnMvRight.Margin = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

$btnMvAllRight = New-Object System.Windows.Forms.Button
$btnMvAllRight.Text   = "Alle >"
$btnMvAllRight.Size   = New-Object System.Drawing.Size(76, 28)
$btnMvAllRight.Margin = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

$btnMvLeft = New-Object System.Windows.Forms.Button
$btnMvLeft.Text   = "<"
$btnMvLeft.Size   = New-Object System.Drawing.Size(76, 28)
$btnMvLeft.Margin = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

$btnMvAllLeft = New-Object System.Windows.Forms.Button
$btnMvAllLeft.Text   = "< Alle"
$btnMvAllLeft.Size   = New-Object System.Drawing.Size(76, 28)
$btnMvAllLeft.Margin = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

$panelArrows.Controls.AddRange(@($btnMvRight, $btnMvAllRight, $btnMvLeft, $btnMvAllLeft))
$panelArrows.Add_Resize({
    $total  = (28 + 8) * 4
    $topPad = [Math]::Max(0, [int](($panelArrows.ClientSize.Height - $total) / 2))
    $panelArrows.Padding = New-Object System.Windows.Forms.Padding(10, $topPad, 10, 0)
})

$tableMain.Controls.Add($lbLeft,      0, 1)
$tableMain.Controls.Add($panelArrows, 1, 1)
$tableMain.Controls.Add($lbRight,     2, 1)

$form.Controls.Add($tableMain)
$form.Controls.Add($separator)
$form.Controls.Add($stripBottom)
$form.Controls.Add($stripTop)
#endregion

#region Owner draw
$clrFound   = [System.Drawing.Color]::FromArgb(0, 140, 0)
$clrUnknown = [System.Drawing.Color]::FromArgb(180, 20, 20)
$clrNormal  = [System.Drawing.SystemColors]::WindowText

$drawItem = [System.Windows.Forms.DrawItemEventHandler]{
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $e.DrawBackground()
    $item  = $sender.Items[$e.Index]
    $color = if ($item.IsFound) { $clrFound } elseif (-not $item.SamAccountName) { $clrUnknown } else { $clrNormal }
    $brush = New-Object System.Drawing.SolidBrush($color)
    $e.Graphics.DrawString($item.DisplayText, $e.Font, $brush, [float]($e.Bounds.X + 3), [float]($e.Bounds.Y + 1))
    $brush.Dispose()
    $e.DrawFocusRectangle()
}
$lbLeft.Add_DrawItem($drawItem)
$lbRight.Add_DrawItem($drawItem)
#endregion

#region Load group
$btnLoadGroup.Add_Click({
    $groupName = $txtGroup.Text.Trim()
    if (-not $groupName) {
        [System.Windows.Forms.MessageBox]::Show("Bitte eine Gruppe angeben.", "Fehler", "OK", "Warning"); return
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $members = Get-ADGroupMember -Identity $groupName -ErrorAction Stop | Where-Object objectClass -eq 'user'
        $script:rightItems.Clear()
        $script:originalRightSAMs.Clear()
        foreach ($m in $members) {
            try {
                $adUser = Get-ADUser -Identity $m.SamAccountName -Properties Name -ErrorAction Stop
                $entry  = & $script:fnNewUserEntry -Raw $m.SamAccountName -SamAccountName $adUser.SamAccountName -ADUser $adUser -IsFound $true
            } catch {
                $entry = & $script:fnNewUserEntry -Raw $m.SamAccountName -IsFound $false
            }
            $script:rightItems.Add($entry)
            [void]$script:originalRightSAMs.Add($m.SamAccountName)
        }
        & $script:fnRefresh $lbRight $script:rightItems
        $form.Text = "AD Gruppenmitglieder verwalten - $groupName"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Gruppe konnte nicht geladen werden:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# AD-Gruppen-Suche Dialog
$btnPickGroup.Add_Click({
    $dlgPick = New-Object System.Windows.Forms.Form
    $dlgPick.Text            = "AD-Gruppe suchen"
    $dlgPick.Size            = New-Object System.Drawing.Size(460, 400)
    $dlgPick.StartPosition   = "CenterParent"
    $dlgPick.MinimizeBox     = $false
    $dlgPick.MaximizeBox     = $false
    $dlgPick.FormBorderStyle = "FixedDialog"
    $dlgPick.Font            = $form.Font

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text     = "Suchbegriff (Gruppenname, * = alle):"
    $lblSearch.Location = New-Object System.Drawing.Point(10, 12)
    $lblSearch.AutoSize = $true

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(10, 32)
    $txtSearch.Width    = 330

    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text     = "Suchen"
    $btnSearch.Location = New-Object System.Drawing.Point(348, 30)
    $btnSearch.Size     = New-Object System.Drawing.Size(85, 26)

    $lbGroups = New-Object System.Windows.Forms.ListBox
    $lbGroups.Location            = New-Object System.Drawing.Point(10, 66)
    $lbGroups.Size                = New-Object System.Drawing.Size(423, 260)
    $lbGroups.ScrollAlwaysVisible = $true
    $lbGroups.IntegralHeight      = $false

    $btnPickOk = New-Object System.Windows.Forms.Button
    $btnPickOk.Text         = "Auswählen"
    $btnPickOk.DialogResult = "OK"
    $btnPickOk.Location     = New-Object System.Drawing.Point(248, 334)
    $btnPickOk.Size         = New-Object System.Drawing.Size(90, 28)
    $btnPickOk.Enabled      = $false

    $btnPickCancel = New-Object System.Windows.Forms.Button
    $btnPickCancel.Text         = "Abbrechen"
    $btnPickCancel.DialogResult = "Cancel"
    $btnPickCancel.Location     = New-Object System.Drawing.Point(346, 334)
    $btnPickCancel.Size         = New-Object System.Drawing.Size(90, 28)

    $dlgPick.Controls.AddRange(@($lblSearch, $txtSearch, $btnSearch, $lbGroups, $btnPickOk, $btnPickCancel))
    $dlgPick.CancelButton = $btnPickCancel

    # Gruppenobjekte als PSCustomObject mit DisplayText + SamAccountName
    $script:pickGroups = @()

    $doSearch = {
        $q = $txtSearch.Text.Trim()
        if (-not $q) { return }
        $dlgPick.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $filter = if ($q -eq '*') { '*' } else { "Name -like '*$q*' -or SamAccountName -like '*$q*'" }
            $found  = Get-ADGroup -Filter $filter -Properties SamAccountName -ResultSetSize 200 -ErrorAction Stop |
                      Sort-Object Name
            $script:pickGroups = @($found | ForEach-Object {
                [PSCustomObject]@{ Display = "$($_.Name)  [$($_.SamAccountName)]"; SAM = $_.SamAccountName }
            })
            $lbGroups.Items.Clear()
            if ($script:pickGroups.Count -eq 0) {
                [void]$lbGroups.Items.Add("(keine Ergebnisse)")
            } else {
                foreach ($g in $script:pickGroups) { [void]$lbGroups.Items.Add($g.Display) }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Suche fehlgeschlagen:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $dlgPick.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $btnSearch.Add_Click($doSearch)
    $txtSearch.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { & $doSearch } })
    $lbGroups.Add_SelectedIndexChanged({
        $btnPickOk.Enabled = ($lbGroups.SelectedIndex -ge 0 -and $lbGroups.SelectedItem -ne "(keine Ergebnisse)")
    })
    $lbGroups.Add_DoubleClick({
        if ($lbGroups.SelectedIndex -ge 0 -and $lbGroups.SelectedItem -ne "(keine Ergebnisse)") {
            $dlgPick.DialogResult = "OK"
            $dlgPick.Close()
        }
    })

    if ($dlgPick.ShowDialog($form) -eq 'OK' -and $lbGroups.SelectedIndex -ge 0) {
        $txtGroup.Text = $script:pickGroups[$lbGroups.SelectedIndex].SAM
    }
})
#endregion

#region CSV import
$btnLoadCsv.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "CSV-Dateien (*.csv)|*.csv|Alle Dateien (*.*)|*.*"
    if ($ofd.ShowDialog($form) -ne 'OK') { return }
    try {
        # Auto-detect delimiter: read first line and compare comma vs semicolon count
        $firstLine = Get-Content -Path $ofd.FileName -TotalCount 1 -ErrorAction Stop
        $delim = if (($firstLine -split ';').Count -gt ($firstLine -split ',').Count) { ';' } else { ',' }
        $csv  = Import-Csv -Path $ofd.FileName -Delimiter $delim -ErrorAction Stop
        $cols = ($csv | Get-Member -MemberType NoteProperty).Name
        # Priorität: UserPrincipalName > mail > SamAccountName > generischer Match > erste Spalte
        $col  = $cols | Where-Object { $_ -imatch '^userprincipalname$' } | Select-Object -First 1
        if (-not $col) { $col = $cols | Where-Object { $_ -imatch '^mail$' }          | Select-Object -First 1 }
        if (-not $col) { $col = $cols | Where-Object { $_ -imatch '^samaccountname$' } | Select-Object -First 1 }
        if (-not $col) { $col = $cols | Where-Object { $_ -imatch 'sam|login|account|user|mail|name' } | Select-Object -First 1 }
        if (-not $col) { $col = $cols | Select-Object -First 1 }
        if (-not $col) {
            [System.Windows.Forms.MessageBox]::Show("Keine Spalten in der CSV gefunden.", "Fehler", "OK", "Warning"); return
        }
        $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $script:leftItems)  { [void]$existing.Add((& $script:fnItemKey $i)); [void]$existing.Add($i.Raw) }
        foreach ($i in $script:rightItems) { [void]$existing.Add((& $script:fnItemKey $i)); [void]$existing.Add($i.Raw) }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $newCount = 0
        foreach ($row in $csv) {
            $sam = ($row.$col).Trim()
            if (-not $sam -or $existing.Contains($sam)) { continue }
            $entry = & $script:fnResolve $sam $col
            if ($null -eq $entry) { continue }
            $script:leftItems.Add($entry)
            [void]$existing.Add((& $script:fnItemKey $entry))
            [void]$existing.Add($sam)
            $newCount++
        }
        & $script:fnRefresh $lbLeft $script:leftItems
        [System.Windows.Forms.MessageBox]::Show("$newCount neue Einträge aus Spalte '$col' (Trennzeichen: '$delim') hinzugefügt.", "CSV geladen", "OK", "Information")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Fehler beim Lesen der CSV:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
#endregion

#region Manual add
$btnManual.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Benutzer manuell hinzufügen"
    $dlg.Size            = New-Object System.Drawing.Size(540, 320)
    $dlg.StartPosition   = "CenterParent"
    $dlg.MinimizeBox     = $false
    $dlg.MaximizeBox     = $false
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.Font            = $form.Font

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text     = "Einen SAM-Accountnamen pro Zeile (Strg+V möglich, Enter = neue Zeile):"
    $lbl2.Location = New-Object System.Drawing.Point(10, 10)
    $lbl2.AutoSize = $true

    $txt2 = New-Object System.Windows.Forms.TextBox
    $txt2.Multiline   = $true
    $txt2.ScrollBars  = "Vertical"
    $txt2.Location    = New-Object System.Drawing.Point(10, 32)
    $txt2.Size        = New-Object System.Drawing.Size(505, 200)
    $txt2.Anchor      = "Left,Top,Right,Bottom"
    $txt2.Font        = New-Object System.Drawing.Font("Consolas", 9)

    $btnDlgOk = New-Object System.Windows.Forms.Button
    $btnDlgOk.Text         = "Hinzufügen"
    $btnDlgOk.DialogResult = "OK"
    $btnDlgOk.Location     = New-Object System.Drawing.Point(340, 244)
    $btnDlgOk.Size         = New-Object System.Drawing.Size(85, 28)

    $btnDlgCancel = New-Object System.Windows.Forms.Button
    $btnDlgCancel.Text         = "Abbrechen"
    $btnDlgCancel.DialogResult = "Cancel"
    $btnDlgCancel.Location     = New-Object System.Drawing.Point(433, 244)
    $btnDlgCancel.Size         = New-Object System.Drawing.Size(85, 28)

    $dlg.Controls.AddRange(@($lbl2, $txt2, $btnDlgOk, $btnDlgCancel))
    # AcceptButton absichtlich nicht gesetzt: Enter soll Zeilenumbruch erzeugen, nicht den Dialog schließen
    $dlg.CancelButton = $btnDlgCancel

    if ($dlg.ShowDialog($form) -ne 'OK') { return }

    $lines = $txt2.Text -split "`r?`n" | Where-Object { $_.Trim() }
    if (-not $lines) { return }

    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $script:leftItems)  { [void]$existing.Add((& $script:fnItemKey $i)); [void]$existing.Add($i.Raw) }
    foreach ($i in $script:rightItems) { [void]$existing.Add((& $script:fnItemKey $i)); [void]$existing.Add($i.Raw) }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        foreach ($line in $lines) {
            $sam = $line.Trim()
            if (-not $sam -or $existing.Contains($sam)) { continue }
            $entry = & $script:fnResolve $sam "SamAccountName"
            if ($null -eq $entry) { continue }
            $script:leftItems.Add($entry)
            [void]$existing.Add((& $script:fnItemKey $entry))
            [void]$existing.Add($sam)
        }
        & $script:fnRefresh $lbLeft $script:leftItems
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
#endregion

#region Arrow buttons
$btnMvRight.Add_Click({
    $selected = @($lbLeft.SelectedItems)
    if (-not $selected) { return }
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $script:rightItems) { [void]$existing.Add((& $script:fnItemKey $i)) }
    foreach ($item in $selected) {
        $key = & $script:fnItemKey $item
        if (-not $existing.Contains($key)) { $script:rightItems.Add($item); [void]$existing.Add($key) }
        [void]$script:leftItems.Remove($item)
    }
    & $script:fnRefresh $lbLeft  $script:leftItems
    & $script:fnRefresh $lbRight $script:rightItems
})

$btnMvAllRight.Add_Click({
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $script:rightItems) { [void]$existing.Add((& $script:fnItemKey $i)) }
    foreach ($item in @($script:leftItems)) {
        $key = & $script:fnItemKey $item
        if (-not $existing.Contains($key)) { $script:rightItems.Add($item); [void]$existing.Add($key) }
    }
    $script:leftItems.Clear()
    & $script:fnRefresh $lbLeft  $script:leftItems
    & $script:fnRefresh $lbRight $script:rightItems
})

$btnMvLeft.Add_Click({
    $selected = @($lbRight.SelectedItems)
    if (-not $selected) { return }
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $script:leftItems) { [void]$existing.Add((& $script:fnItemKey $i)) }
    foreach ($item in $selected) {
        $key = & $script:fnItemKey $item
        if (-not $existing.Contains($key)) { $script:leftItems.Add($item); [void]$existing.Add($key) }
        [void]$script:rightItems.Remove($item)
    }
    & $script:fnRefresh $lbLeft  $script:leftItems
    & $script:fnRefresh $lbRight $script:rightItems
})

$btnMvAllLeft.Add_Click({
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $script:leftItems) { [void]$existing.Add((& $script:fnItemKey $i)) }
    foreach ($item in @($script:rightItems)) {
        $key = & $script:fnItemKey $item
        if (-not $existing.Contains($key)) { $script:leftItems.Add($item); [void]$existing.Add($key) }
    }
    $script:rightItems.Clear()
    & $script:fnRefresh $lbLeft  $script:leftItems
    & $script:fnRefresh $lbRight $script:rightItems
})
#endregion

#region Remove from left list
$btnRemove.Add_Click({
    $selected = @($lbLeft.SelectedItems)
    if (-not $selected) { return }
    foreach ($item in $selected) { [void]$script:leftItems.Remove($item) }
    & $script:fnRefresh $lbLeft $script:leftItems
})

# Entf-Taste in der linken Liste ebenfalls entfernen
$lbLeft.Add_KeyDown({
    if ($_.KeyCode -eq 'Delete') {
        $selected = @($lbLeft.SelectedItems)
        foreach ($item in $selected) { [void]$script:leftItems.Remove($item) }
        & $script:fnRefresh $lbLeft $script:leftItems
    }
})
#endregion

#region Save
$btnSave.Add_Click({
    $groupName = $txtGroup.Text.Trim()
    if (-not $groupName) {
        [System.Windows.Forms.MessageBox]::Show("Bitte eine Gruppe angeben.", "Fehler", "OK", "Warning"); return
    }
    $targetSAMs      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unresolvedItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($i in $script:rightItems) {
        if ($i.SamAccountName) { [void]$targetSAMs.Add($i.SamAccountName) }
        else                   { $unresolvedItems.Add($i) }
    }
    $unresolved = @($unresolvedItems | ForEach-Object { $_.Raw })
    $toAdd    = @($targetSAMs                  | Where-Object { -not $script:originalRightSAMs.Contains($_) })
    $toRemove = @($script:originalRightSAMs    | Where-Object { -not $targetSAMs.Contains($_) })
    if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
        $extra = if ($unresolved.Count -gt 0) { "`n`n$($unresolved.Count) nicht aufgelöste Einträge werden ignoriert." } else { "" }
        [System.Windows.Forms.MessageBox]::Show("Keine Änderungen erkannt.$extra", "Speichern", "OK", "Information"); return
    }
    $msg = "Änderungen fuer '$groupName' speichern?`n`n"
    if ($toAdd.Count    -gt 0) { $msg += "Hinzufügen : $($toAdd.Count) Benutzer`n" }
    if ($toRemove.Count -gt 0) { $msg += "Entfernen   : $($toRemove.Count) Benutzer`n" }
    if ($unresolved.Count -gt 0) { $msg += "`nIgnoriert (nicht aufgelöst): $($unresolved.Count)`n" }
    if ([System.Windows.Forms.MessageBox]::Show($msg, "Bestätigen", "YesNo", "Question") -ne 'Yes') { return }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $errs = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($sam in $toAdd)    {
            try   { Add-ADGroupMember -Identity $groupName -Members $sam -ErrorAction Stop }
            catch { $errs.Add("+ $sam : $($_.Exception.Message)") }
        }
        foreach ($sam in $toRemove) {
            try   { Remove-ADGroupMember -Identity $groupName -Members $sam -Confirm:$false -ErrorAction Stop }
            catch { $errs.Add("- $sam : $($_.Exception.Message)") }
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    # Nicht aufgelöste Einträge in Zwischenablage kopieren
    if ($unresolvedItems.Count -gt 0) {
        $srcCols = @($unresolvedItems | Select-Object -ExpandProperty SourceColumn -Unique)
        if ($srcCols.Count -eq 1) {
            $csvLines = @($srcCols[0])
            foreach ($i in $unresolvedItems) { $csvLines += $i.Raw }
        } else {
            $csvLines = @("SourceColumn,Value")
            foreach ($i in $unresolvedItems) { $csvLines += "$($i.SourceColumn),$($i.Raw)" }
        }
        [System.Windows.Forms.Clipboard]::SetText($csvLines -join "`r`n")
    }

    if ($errs.Count -gt 0) {
        $clipHint = if ($unresolved.Count -gt 0) { "`n`n$($unresolved.Count) nicht aufgelöste Einträge wurden in die Zwischenablage kopiert." } else { "" }
        [System.Windows.Forms.MessageBox]::Show("Abgeschlossen mit Fehlern:`n`n" + ($errs -join "`n") + $clipHint, "Warnung", "OK", "Warning")
    } else {
        $clipHint = if ($unresolved.Count -gt 0) { "`n`n$($unresolved.Count) nicht aufgelöste Einträge wurden als CSV in die Zwischenablage kopiert." } else { "" }
        [System.Windows.Forms.MessageBox]::Show("Erfolgreich gespeichert.$clipHint", "Gespeichert", "OK", "Information")
    }
    $script:originalRightSAMs.Clear()
    foreach ($i in $script:rightItems) {
        if ($i.SamAccountName) { [void]$script:originalRightSAMs.Add($i.SamAccountName) }
    }
})
#endregion

$txtGroup.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $btnLoadGroup.PerformClick() } })

[void]$form.ShowDialog()
$form.Dispose()