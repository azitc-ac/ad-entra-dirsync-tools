Import-Module ActiveDirectory

# Pfad zur CSV-Datei
$csvPath = "C:\tools\scripts\Users_(OU=Users,OU=HomeOU,DC=home,DC=local).csv"

# target OU
$OU = "OU=Import,OU=Users,OU=TESTOU,DC=test,DC=local"

# Liste der zu importierenden Attribute (kommentierbar)
$importKeys = @(
    'SamAccountName','Name','GivenName',
    #'sn',
    'UserPrincipalName','DisplayName',
    'Department','Company','Division','EmployeeID','EmployeeNumber',
    #'mail',
    'OfficePhone','MobilePhone','HomePhone','StreetAddress','City','State','PostalCode',
    'Country',
    #'c','co','countryCode','physicalDeliveryOfficeName',
    'HomeDirectory','HomeDrive','ProfilePath',
    #'Manager',
    'Office','Description','Title',
    #'primaryGroupID',
    #'logonHours',
    'PasswordNeverExpires','Initials','proxyAddresses',
    'extensionAttribute1','extensionAttribute2','extensionAttribute3','extensionAttribute4',
    'extensionAttribute5','extensionAttribute6','extensionAttribute7','extensionAttribute8',
    'extensionAttribute9','extensionAttribute11','extensionAttribute12','extensionAttribute13',
    'extensionAttribute14','extensionAttribute15'
)

# Direkt unterstützte Parameter
$directKeys = @(
    'SamAccountName','Name','GivenName','Surname','UserPrincipalName','DisplayName',
    'Department','Company','Division','EmployeeID','EmployeeNumber','EmailAddress',
    'OfficePhone','MobilePhone','HomePhone','StreetAddress','City','State','PostalCode',
    'Country','c','co','countryCode','physicalDeliveryOfficeName','HomeDirectory',
    'HomeDrive','ProfilePath','Office','Description','Title',
    'PasswordNeverExpires','Initials','Enabled','AccountPassword','Path'
)

# Boolesche Felder
$boolFields = @('Enabled', 'PasswordNeverExpires')

function Get-NonEmptyHashtable {
    param (
        [hashtable]$InputHashtable
    )

    $filtered = @{}
    foreach ($key in $InputHashtable.Keys) {
        $value = $InputHashtable[$key]
        if ($null -ne $value -and $value -ne '') {
            $filtered[$key] = $value
        }
    }
    return $filtered
}

# CSV einlesen
$users = Import-Csv -Path $csvPath -Delimiter ";"

# Anzahl der Benutzer
$total = $users.Count
$counter = 0
foreach ($user in $users) {
    $counter++
    $percentComplete = [int](($counter / $total) * 100)
    $sam = $user.SamAccountName

    Write-Progress -Activity "Benutzerimport läuft..." `
                   -Status "Verarbeite '$sam' ($counter von $total)" `
                   -PercentComplete $percentComplete

    if (-not $sam) {
        Write-Warning "SamAccountName fehlt – überspringe Zeile."
        continue
    }

        # Initiale Parameter
    $rawParams = @{
        SamAccountName                = $user.SamAccountName
        Name                          = $user.Name
        GivenName                     = $user.GivenName
        Surname                       = $user.sn
        UserPrincipalName             = $user.UserPrincipalName
        AccountPassword               = (ConvertTo-SecureString "TempP@ssw0rd!" -AsPlainText -Force)
        Enabled                       = $true
        Path                          = $OU
        DisplayName                   = $user.DisplayName
        Department                    = $user.Department
        Company                       = $user.Company
        Division                      = $user.Division
        EmployeeID                    = $user.EmployeeID
        EmployeeNumber                = $user.EmployeeNumber
        EmailAddress                  = $user.mail
        OfficePhone                   = $user.OfficePhone
        MobilePhone                   = $user.MobilePhone
        HomePhone                     = $user.HomePhone
        StreetAddress                 = $user.StreetAddress
        City                          = $user.City
        State                         = $user.State
        PostalCode                    = $user.PostalCode
        Country                       = $user.Country
        #c                             = $user.c
        #co                            = $user.co
        #countryCode                   = $user.countryCode
        #physicalDeliveryOfficeName    = $user.physicalDeliveryOfficeName
        HomeDirectory                 = $user.HomeDirectory
        HomeDrive                     = $user.HomeDrive
        ProfilePath                   = $user.ProfilePath
        #Manager                       = $user.Manager
        Office                        = $user.Office
        Description                   = $user.Description
        Title                         = $user.Title
        #primaryGroupID                = $user.primaryGroupID
        #logonHours                    = $user.logonHours
        PasswordNeverExpires          = $user.PasswordNeverExpires
        Initials                      = $user.Initials
        proxyAddresses                = $user.proxyAddresses
        extensionAttribute1           = $user.extensionAttribute1
        extensionAttribute2           = $user.extensionAttribute2
        extensionAttribute3           = $user.extensionAttribute3
        extensionAttribute4           = $user.extensionAttribute4
        extensionAttribute5           = $user.extensionAttribute5
        extensionAttribute6           = $user.extensionAttribute6
        extensionAttribute7           = $user.extensionAttribute7
        extensionAttribute8           = $user.extensionAttribute8
        extensionAttribute9           = $user.extensionAttribute9
        extensionAttribute11          = $user.extensionAttribute11
        extensionAttribute12          = $user.extensionAttribute12
        extensionAttribute13          = $user.extensionAttribute13
        extensionAttribute14          = $user.extensionAttribute14
        extensionAttribute15          = $user.extensionAttribute15
    }

    # Gewünschte Attribute aus CSV übernehmen
    foreach ($key in $importKeys) {
        if ($user.PSObject.Properties[$key]) {
            $value = $user.$key
            if ($value -ne $null -and $value -ne "") {
                $rawParams[$key] = $value
            }
        }
    }

    # Aufteilen in direkte und LDAP-Attribute
    $directParams = @{}
    $ldapParams = @{}

    foreach ($key in $rawParams.Keys) {
        $value = $rawParams[$key]

        # Bool-Konvertierung
        if ($boolFields -contains $key) {
            try {
                $value = [bool]$value
            } catch {
                Write-Warning "Ungültiger Bool-Wert für '$key' bei '$sam': '$value'"
                continue
            }
        }

        if ($key -eq 'proxyAddresses') {
            if ($value -is [string]) {
                $value = $value -split ';' | Where-Object { $_.Trim() -ne '' }
            } elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                $value = @($value)  # sicherstellen, dass es ein echtes Array ist
            } else {
                Write-Warning "Ungültiger Typ für proxyAddresses bei '$sam': $($value.GetType().Name)"
                continue
            }
        }
        if ($directKeys -contains $key) {
            $directParams[$key] = $value
        } else {
            $ldapParams[$key] = $value
        }
    }

    if ($ldapParams.ContainsKey('proxyAddresses')) {
        $proxy = $ldapParams['proxyAddresses']
        if ($proxy -isnot [string[]]) {
            $proxy = @($proxy | ForEach-Object { [string]$_ })
            $ldapParams['proxyAddresses'] = $proxy
        }
    }

    $directParams = Get-NonEmptyHashtable $directParams
    $ldapParams = Get-NonEmptyHashtable $ldapParams

    try {
        New-ADUser @directParams
        if ($ldapParams.Count -gt 0) {
            Set-ADUser -Identity $sam -Replace $ldapParams -Verbose
        }
        Write-Host "Benutzer '$sam' erstellt." -ForegroundColor Cyan
    } catch {
        Write-Warning "Fehler beim Erstellen von '$sam': $_"
    }
}

Write-Progress -Activity "Benutzerimport abgeschlossen" -Completed