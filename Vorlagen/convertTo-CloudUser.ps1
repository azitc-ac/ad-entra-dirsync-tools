
#$PSVersionTable
#Get-module PowershellGet | ft
#Find-module PowershellGet | ft
#Install-Module PowershellGet -Force
#Install-Module Microsoft.Graph.Entra -AllowPrerelease -Repository PSGallery -Force
#Connect-Entra -Scopes 'User.Read.All,AuditLog.Read.All'

$cloudTenant = "contoso.onmicrosoft.com"
$cleandatetime = get-date -uformat "%Y-%m-%d_%H-%M-%S"
$outfile="C:\Temp\AllUsersWithImmutableId"+"_"+$cleandatetime+".csv"

Connect-MgGraph -Scopes 'User.ReadWrite.All'
#Connect-MgGraph -Scopes 'User.ReadWrite.All, Domain.ReadWrite.All, Directory.AccessAsUser.All'
#Import-Module activedirectory

#$newgroup = "AAD_TESTGRUPPE"
#$groupObj = Get-MgGroup -GroupId $newgroup

# show a dialog and let the user select the destination OU for the target mailbox
$OU=Get-ADOrganizationalUnit -Filter * | select DistinguishedName,Name | ogv -PassThru -Title "User conversion: Select OU containing the desired user accounts"
$OU=$OU.DistinguishedName

[array]$users=Get-ADUser -Filter * -SearchBase $OU | ogv -PassThru -Title "User conversion: Select the desired user accounts"
$extattr = "extensionAttribute5"
$extattrValue = "F1"

$itemtotalcount=$Users.Count
$itemcount=1
[array]$userstep2 = $null

Write-Host "`nExporting user accounts to CSV and setting $($extattr)" -ForegroundColor Cyan
foreach($user in $users){
    $OldUPN = $user.userPrincipalName
    #$NewUPN = "admin@example.com"    
 
    $UserName = ($OldUPN -split '@')[0]
    $tempUPN = "${userName}@${cloudTenant}"
    
    $progress = $itemcount / $itemtotalcount *100 ;
    Write-Progress -Activity "Add extensionAttribute" -PercentComplete $progress -Status "$itemcount/$itemtotalcount - Processing [$OldUPN]"
    $itemcount++

    ### step 1 - export & set extattr
    $userObj=$null
    $userObj = Get-MgUser -UserId $OldUPN -Property OnPremisesImmutableId,DisplayName,Id,Mail,UserPrincipalName,extensionAttribute5 -ErrorAction SilentlyContinue
    
    if($userobj){
        write-host "Exporting [$OldUPN] to CSV"
        $userObj | select OnPremisesImmutableId,DisplayName,Id,Mail,UserPrincipalName | export-csv -Path $outfile -Append -Delimiter ";" -NoTypeInformation -Encoding UTF8
        #write-host "Removing ImmutableId for [$OldUPN] now..." -NoNewline
        #Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/Users/$OldUPN" -Body @{OnPremisesImmutableId = " "}
        #$userObjPost = $null
        #$userObjPost = Get-MgUser -UserId $OldUPN -Property OnPremisesImmutableId,DisplayName,Id,Mail,UserPrincipalName,extensionAttribute5         
        #if($userObjPost){if($userObj.OnPremisesImmutableId -ne $null -or $userObj.OnPremisesImmutableId -eq "" -or $userObj.OnPremisesImmutableId -ne " "){write-host "[$OldUPN] still has an ImmutableId!" -ForegroundColor red}else{write-host "Success" -ForegroundColor Green}}
        $user | Set-ADUser -Clear $extattr
        $user | Set-ADUser -Add @{$extattr=$extattrValue}
        $userstep2 += $user
    }
    else{
        Write-Host "User [$OldUPN] nicht gefunden" -ForegroundColor Yellow
    }
}
Write-Progress -Activity "Add extensionAttribute" -PercentComplete $progress -Completed
"ExtensionAttribute result:"
$users | Get-ADUser -Properties * | select userprincipalname,$extattr | Out-String

### step 2 - user aus dem sync scope nehmen, sync durchführen, was zur Löschung in ENtra führt (Papierkorb)
$newOU=Get-ADOrganizationalUnit -Filter * | select DistinguishedName,Name | ogv -PassThru -Title "User conversion 3/3: Select target OU which is out of sync scope for the previously selected user accounts"
Write-Host "`nMoving user accounts to OU $($newOU.DistinguishedName)" -ForegroundColor Cyan
$userstep2  | %{"Moving $_";Move-ADObject $_ -TargetPath $newOU.DistinguishedName}

Write-Host "`nNow perform a sync and check the results. If everything ran smoothly return here and continue." -ForegroundColor Cyan
pause
### step 3 - user restoren

#region user restore from recycle bin ################### hier muss noch eine routine rein, dass nur die returned werden, die auch zuvor gelöscht wurden
Write-Host "`nRestoring accounts from recycle bin" -ForegroundColor Cyan
$itemcount = 1
$itemtotalcount=$Users.Count
foreach($user in $users){
    $OldUPN = $user.userPrincipalName
    #$NewUPN = "admin@example.com"    
 
    $UserName = ($OldUPN -split '@')[0]
    $tempUPN = "${userName}@${cloudTenant}"
    
    $progress = $itemcount / $itemtotalcount *100 ;
    Write-Progress -Activity "Restore user from recycle bin" -PercentComplete $progress -Status "$itemcount/$itemtotalcount - Processing [$OldUPN]"
    $itemcount++

    # I do the Url like this because $OldUPN is a variable and I want PowerShell to treat it like that. Also, I am not sure if $count is required, but I add it as a just in case coz some searches require it. No harm adding. 
    $filterUrl = 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$filter=endsWith(userPrincipalName,'
    $filterUrl = $filterUrl + "'$OldUPN')" + '&$count=true'
    # OR: all users
    #$filterUrl = 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?'
 
    $deletedObj = Invoke-MgGraphRequest -Uri $filterUrl -Headers @{ ConsistencyLevel = "eventual" }
 
    if ($deletedObj.'@odata.count' -eq 0) {
        # Output error or do nothing
    } 
    else {
        $arrayofDeletedUsers=$deletedObj.value
        foreach($deleteduser in $arrayofDeletedUsers){
            $userId = $deleteduser.id
            $displayName = $deleteduser.displayName
            Write-Host "Restoring [$displayName]..." -NoNewline
            Restore-MgDirectoryDeletedItem -DirectoryObjectId $userid | Out-Null
 
            #Update-MgUser -UserId $userId -UserPrincipalName $tempUPN
            #Update-MgUser -UserId $userId -OnPremisesImmutableId $newImmutableId
            #Update-MgUser -UserId $userId -UserPrincipalName $NewUPN
            $userObj = $null
            $userObj = Get-MgUser -UserId $OldUPN
            if ($userObj) {
                Write-Host "All good!" -ForegroundColor Green
            }
        }
    }    
}
#Write-Progress -Activity "Restore user from recycle bin" -PercentComplete $progress -Completed

#endregion user restore

