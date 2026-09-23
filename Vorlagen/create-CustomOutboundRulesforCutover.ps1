#
#$domains2cutover = "@alt.example.com", "@neu.example.com", "@neu.example.com"
# 1 domain
$domains2cutover = @('@alt.example.com')
# more domains
# 3
#$domains2cutover = '@dom1.de', '@dom2.de', '@dom3.de'
# 5
#$domains2cutover = '@dom1.de', '@dom2.de', '@dom3.de', '@alt.example.com', 'example.com'

$domaincount = $domains2cutover.Count

$remainingdomain = "@azitc75.onmicrosoft.com"
$onpremUpnDomain2add = "@example.local"

# Pfad zur Original Exportdatei mit diesen per UI exportierten Regeln
<# Export of these rules:
$rules=@(
'Out to AAD - User Identity'
'Out to AAD - User ExchangeOnline'
'Out to AAD - User DynamicsCRM'
'Out to AAD - User Intune'
'Out to AAD - User LyncOnline'
'Out to AAD - User SharePointOnline'
'Out to AAD - User AzureRMS'
'Out to AAD - User OfficeProPlus'
)
#>
$workdir = $PSScriptRoot
cd $workdir
$cleandatetime = get-date -uformat "%Y-%m-%d_%H-%M-%S"

Add-Type -AssemblyName System.Windows.Forms

$fileDialog = New-Object System.Windows.Forms.OpenFileDialog
$fileDialog.Title = "Select an input file"
$fileDialog.Filter = "All files (*.*)|*.*"
$fileDialog.Multiselect = $false

$result = $fileDialog.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    $filepath = $fileDialog.FileName
}

# Dateiinhalt lesen
$content = Get-Content -Path $filePath

# Liste für die Objekte initialisieren
$objectList = @()

# Temporäres Objekt initialisieren
$tempObject = $null

# Schleife durch den Inhalt und finde die Passagen, die jeweils eine Rule o.ä. darstellen
foreach ($line in $content) {
    if ($line -match "New-ADSyncRule") {
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "New-ADSyncRule"
    } elseif($line -match "Add-ADSyncAttributeFlowMapping"){
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}    
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "Add-ADSyncAttributeFlowMapping"
    } elseif($line -match "New-Object"){
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "New-Object"
        $dbg=1
    } elseif($line -match "Add-ADSyncScopeConditionGroup"){
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "Add-ADSyncScopeConditionGroup"
    } elseif($line -match "Add-ADSyncRule"){
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "Add-ADSyncRule"
    } elseif($line -match "Get-ADSyncRule"){
        # Wenn eine neue Passage beginnt, füge das vorherige Objekt zur Liste hinzu
        if ($tempObject -ne $null) {
            $objectList += $tempObject
        }
        # Neues temporäres Objekt initialisieren
        $tempObject = [PSCustomObject]@{}
        $tempObject | Add-Member -MemberType NoteProperty -Name "Command" -Value "Get-ADSyncRule"
    }
    else{
        if($dbg -eq 1){
            "Huhu"
        }
        #if($line -match "^\s*-\w+\s+.+\s*``") {
        if($line -match "^\s*-\w+\s+.+\s*(``)?$"){
            # Zeile parsen und zum temporären Objekt hinzufügen
            $line = $line -replace "``", "" # Entferne den Backtick
            $parts = $line -split "\s+", 2
            $property = $parts -replace "^-", "" | select -First 1
            #$value = $parts
            $value = $parts[1..($parts.Length - 1)] -join " "
            # remove single quotes
            $value = $value.TrimStart("'").Trim(" ").Trim("'")
            if ($tempObject -ne $null) {
                $tempObject | Add-Member -MemberType NoteProperty -Name $property -Value $value
            }
        }
    }
}

# Füge das letzte Objekt zur Liste hinzu
if ($tempObject -ne $null) {
    $objectList += $tempObject
}

# Ausgabe der Liste von Objekten
# Nun haben wir eine Liste von Objekten mit den kompletten Regeldefinitionen
#$objectList 


#remove vanity domain from mail, proxyaddresses, upn, msRtcSipPrimaryUserAddress, onPremisesUserPrincipalName
$objectList2 = @()
$tempObject2 = $null

foreach($object in $objectList){
    write-host "Processing Command: $($object.Command) ;Name: $($object.Name) ;Source: $($object.Source); Source: $($object.Destination)" -ForegroundColor Cyan
    if($object.command -eq "New-ADSyncRule"){
        <#change 
            Name to "CUSTOM - xyz", 
            Identifier to a new GUID, 
            Description to "Copy of <originalName>", 
            Precedence to Precedence+100, 
            ImmutableTag to an empty string
        #>
        $object.Name = "CUSTOM - $($object.Name)"
        $object.Identifier = [guid]::NewGuid()
        $object.Precedence = [int]($object.Precedence) + 100
        $object.Description = "Copy of $($object.Name) - Used to support domain cutover"
        $object.ImmutableTag = ""

        #if ($tempObject2 -ne $null) {
            $tempObject2 = $object
            $objectList2 += $tempObject2
        #}
        # Neues temporäres Objekt initialisieren
        $tempObject2 = [PSCustomObject]@{}
    }
    elseif($object.command -eq "Add-ADSyncAttributeFlowMapping"){
        <#remove vanity domain from 
            mail, 
            proxyaddresses, 
            upn, 
            msRtcSipPrimaryUserAddress, 
            onPremisesUserPrincipalName
        #>
        if($object.Source){
            if($object.Source.Trim() -eq "@('mail')"){
                $object.FlowType = "Expression"
                switch ($domaincount){
                    1 {$expressionvalue = "Replace([mail],`"$($domains2cutover[0])`",`"$remainingdomain`")"}
                    3 {$expressionvalue = "Replace(Replace(Replace(LCase([mail]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`")"}
                    5 {$expressionvalue = "Replace(Replace(Replace(Replace(Replace(LCase([mail]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`"), `"$($domains2cutover[3])`", `"$remainingdomain`"), `"$($domains2cutover[4])`", `"$remainingdomain`")"}
                }
                $object | Add-Member -MemberType NoteProperty -Name "Expression" -Value $expressionvalue
            }
            if($object.Source.Trim() -eq "@('proxyAddresses')"){
                $object.FlowType = "Expression"
                switch ($domaincount){
                    1 {$expressionvalue = "Replace([proxyAddresses],`"$($domains2cutover[0])`",`"$remainingdomain`")"}
                    3 {$expressionvalue = "Replace(Replace(Replace(LCase([proxyAddresses]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`")"}
                    5 {$expressionvalue = "Replace(Replace(Replace(Replace(Replace(LCase([proxyAddresses]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`"), `"$($domains2cutover[3])`", `"$remainingdomain`"), `"$($domains2cutover[4])`", `"$remainingdomain`")"}
                }
                $object | Add-Member -MemberType NoteProperty -Name "Expression" -Value $expressionvalue
            }
            if($object.Source.Trim() -eq "@('userPrincipalName')"){
                $object.FlowType = "Expression"
                switch ($domaincount){
                    1 {$expressionvalue = "Replace([userPrincipalName],`"$($domains2cutover[0])`",`"$remainingdomain`")"}
                    3 {$expressionvalue = "Replace(Replace(Replace(LCase([userPrincipalName]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`")"}
                    5 {$expressionvalue = "Replace(Replace(Replace(Replace(Replace(LCase([userPrincipalName]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`"), `"$($domains2cutover[3])`", `"$remainingdomain`"), `"$($domains2cutover[4])`", `"$remainingdomain`")"}
                }
                $object | Add-Member -MemberType NoteProperty -Name "Expression" -Value $expressionvalue
            }        
            if($object.Source.Trim() -eq "@('onPremisesUserPrincipalName')"){
                $object.FlowType = "Expression"
                switch ($domaincount){
                    1 {$expressionvalue = "Replace([onPremisesUserPrincipalName],`"$($domains2cutover[0])`",`"$onpremUpnDomain2add`")"}
                    3 {$expressionvalue = "Replace(Replace(Replace(LCase([onPremisesUserPrincipalName]), `"$($domains2cutover[0])`", `"$onpremUpnDomain2add`"), `"$($domains2cutover[1])`", `"$onpremUpnDomain2add`"), `"$($domains2cutover[2])`", `"$onpremUpnDomain2add`")"}
                    5 {$expressionvalue = "Replace(Replace(Replace(Replace(Replace(LCase([onPremisesUserPrincipalName]), `"$($domains2cutover[0])`", `"$onpremUpnDomain2add`"), `"$($domains2cutover[1])`", `"$onpremUpnDomain2add`"), `"$($domains2cutover[2])`", `"$remainingdomain`"), `"$($domains2cutover[3])`", `"$onpremUpnDomain2add`"), `"$($domains2cutover[4])`", `"$onpremUpnDomain2add`")"}
                }
                $object | Add-Member -MemberType NoteProperty -Name "Expression" -Value $expressionvalue
            } 
            if($object.Source.Trim() -eq "@('msRtcSipPrimaryUserAddress')"){
                $object.FlowType = "Expression"
                switch ($domaincount){
                    1 {$expressionvalue = "Replace([msRtcSipPrimaryUserAddress],`"$($domains2cutover[0])`",`"$remainingdomain`")"}
                    3 {$expressionvalue = "Replace(Replace(Replace(LCase([msRtcSipPrimaryUserAddress]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`")"}
                    5 {$expressionvalue = "Replace(Replace(Replace(Replace(Replace(LCase([msRtcSipPrimaryUserAddress]), `"$($domains2cutover[0])`", `"$remainingdomain`"), `"$($domains2cutover[1])`", `"$remainingdomain`"), `"$($domains2cutover[2])`", `"$remainingdomain`"), `"$($domains2cutover[3])`", `"$remainingdomain`"), `"$($domains2cutover[4])`", `"$remainingdomain`")"}
                }
                $object | Add-Member -MemberType NoteProperty -Name "Expression" -Value $expressionvalue
            } 
        }
        if ($tempObject2 -ne $null) {
            $tempObject2 = $object
            $objectList2 += $tempObject2
        }
        # Neues temporäres Objekt initialisieren
        $tempObject2 = [PSCustomObject]@{}

    }
    else{ # wenn es ein anderes objekt ist

        #if ($tempObject2 -ne $null) {
            $tempObject2 = $object
            $objectList2 += $tempObject2
        #}
        # Neues temporäres Objekt initialisieren
        $tempObject2 = [PSCustomObject]@{}

    
    }

}
# Füge das letzte Objekt zur Liste hinzu
if ($tempObject2 -ne $null) {
    $objectList2 += $tempObject2
}

#>

#exportiere verändertes .ps1

$objectList2

$outfile= (get-item $filePath).BaseName + "_ChangedforCutover.ps1"
if(Test-Path $outfile){del $outfile -Force}

# Schleife durch die Objektliste und formatiere die Ausgabe
foreach ($obj in $objectList2) {
    $output = $obj.Command
    foreach ($property in $obj.PSObject.Properties) {
        if ($property.Name -ne "Command") {
            if($property.Name -eq "OutVariable"`
                -or $property.Name -eq "SynchronizationRule" `
                -or $property.Name -eq "Source" `
                -or $property.Name -eq "ScopeConditions" `
                -or ([int]::TryParse($property.Value, [ref]$null)))`
            {
                #ohne Anführungszeichen
                $output += " -$($property.Name) $($property.Value)"
            }
            else{
                # mit einfachen Anführungszeichen
                $output += " -$($property.Name) `'$($property.Value)`'"
            }
        }
    }
    Write-Output $output
    $output | out-File $outfile -Append
}
