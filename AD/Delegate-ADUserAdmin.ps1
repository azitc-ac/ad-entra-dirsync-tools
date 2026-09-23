function Assert-Dsacls {
    if (-not (Get-Command dsacls.exe -ErrorAction SilentlyContinue)) {
        throw "dsacls.exe nicht gefunden. Bitte RSAT / AD DS-Tools installieren."
    }
}

function Invoke-Dsacls {
    param(
        [string]$OuDN,
        [string]$Principal,
        [string]$PermissionStatement,
        [string]$InheritanceSwitch # "", "/I:S" oder "/I:T" etc.
    )
    $args = @("`"$OuDN`"")
    if ($InheritanceSwitch) { $args += $InheritanceSwitch }
    $args += @("/G", "$Principal`:$PermissionStatement")

    if ($WhatIf) {
        Write-Host "WhatIf: dsacls $($args -join ' ')" -ForegroundColor Yellow
    } else {
        & dsacls.exe @args | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "dsacls Fehler (ExitCode $LASTEXITCODE) bei '$PermissionStatement'."
        }
    }
}

function get-OUs{
    $AccountTypes = @(
        "External"
        "Frontline Workers"
        "Service Accounts"
        "Users"
        "Administrative Users"
    )
    $AdditionalOUs = @(
        "Deactivated Users"
        "Users_without_MFA"
        "Test_IT"
    )

    $OUs = @()
    #$OUs += "OU=Users,OU=Germany,OU=Prym Holding,DC=Prym,DC=com"
    #$OUs += "DC=Prym,DC=com"
    #$OUs += "OU=Test_IT,OU=Germany,OU=Prym Holding,DC=Prym,DC=com"
    foreach($AccountType in $AccountTypes){
        $OUs += (Get-ADOrganizationalUnit -Filter 'name -eq $AccountType').distinguishedName
        if($AccountType -eq "Administrative Users"){
            $base = (Get-ADOrganizationalUnit -Filter 'name -eq $AccountType').distinguishedName
            $OUs += (Get-ADOrganizationalUnit -SearchBase $base -Filter *).distinguishedName
            #write-host "Found: "
        }
    }
    foreach($AdditionalOU in $AdditionalOUs){
        $OUs += (Get-ADOrganizationalUnit -Filter 'name -eq $AdditionalOU').distinguishedName
    }
    $OUs = $OUs | select -Unique # removes any duplicates
    return $OUs
}

$scriptDirectory = "C:\Powershell"

$OUs = get-OUs
$OUs = $OUs | ogv -PassThru -Title "Select the OUs containing the relevant user objects..."
$ServiceAccount = "HOME\svc_ADCleanup"
$Principal = $ServiceAccount

#region START get values for objecttype guids for friendly ACL display
Write-Host "Inititalizing..." -ForegroundColor Cyan
$ObjectTypeGUID = @{}
$GetADObjectParameter = @{
    SearchBase = (Get-ADRootDSE).SchemaNamingContext
    LDAPFilter = '(SchemaIDGUID=*)'
    Properties = @("Name", "SchemaIDGUID")
}
$SchGUID = Get-ADObject @GetADObjectParameter
Foreach ($SchemaItem in $SchGUID) {
    $ObjectTypeGUID.Add([GUID]$SchemaItem.SchemaIDGUID, $SchemaItem.Name)  | Out-Null
}
$ADObjExtPar = @{
    SearchBase = "CN=Extended-Rights,$((Get-ADRootDSE).ConfigurationNamingContext)"
    LDAPFilter = '(ObjectClass=ControlAccessRight)'
    Properties = @("Name", "RightsGUID")
}
$SchExtGUID = Get-ADObject @ADObjExtPar
ForEach ($SchExtItem in $SchExtGUID) {
    try {
        $ObjectTypeGUID.Add([GUID]$SchExtItem.RightsGUID, $SchExtItem.Name)
    }
    catch [ArgumentException] {
        #"already included"
    }
}
#endregion

foreach($OuDN in $OUs){
    try {
        Assert-Dsacls
        Write-Host "Delegation wird auf OU '$OuDN' für '$Principal' konfiguriert ..." -ForegroundColor Cyan

        # 1) description: nur User-Objekte (Inherited Object Type -> /I:S)
        Invoke-Dsacls -OuDN $OuDN -Principal $Principal -PermissionStatement "RPWP;description;user" -InheritanceSwitch "/I:S"

        # 2) userAccountControl: nur User-Objekte (Inherited Object Type -> /I:S)
        Invoke-Dsacls -OuDN $OuDN -Principal $Principal -PermissionStatement "RPWP;userAccountControl;user" -InheritanceSwitch "/I:S"

        # 3a) Delete Child für user-Objekte auf dem Container (kein Inherited Object Type)
        Invoke-Dsacls -OuDN $OuDN -Principal $Principal -PermissionStatement "DC;user" -InheritanceSwitch ""

        # 3b) Delete (SD) auf User-Objekten via Vererbung (Inherited Object Type -> /I:S)
        Invoke-Dsacls -OuDN $OuDN -Principal $Principal -PermissionStatement "SD;;user" -InheritanceSwitch "/I:S"

        Write-Host "Fertig. ACL der OU:" -ForegroundColor Green
        if ($WhatIf) { Write-Host "WhatIf: dsacls `"$OuDN`"" }
        else { 
            #& dsacls.exe "`"$OuDN`"" | Out-Null 
            $out = (Get-Acl -Path "AD:\$OuDN").Access | ? { $_.IdentityReference -eq $Principal } | select IdentityReference, ActiveDirectoryRights, AccessControlType, @{Name = "ObjectType"; Expression = { $obj = $_.ObjectType; $ObjectTypeGUID[[GUID]$obj] } }    
            $out | Out-Host
        }

        #Write-Host "`nHinweis: 'Vor versehentlichem Löschen schützen' setzt Deny-ACEs (Delete/Delete Subtree) am Objekt und blockiert Löschvorgänge trotz obiger Delegation. Vor dem Löschen ggf. den Schutz entfernen." -ForegroundColor DarkYellow

    } catch {
        Write-Error $_
    }
}