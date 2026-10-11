# DirSync

Alles, was zwischen Active Directory und Entra ID vermittelt: die Umstellung von Anmeldenamen,
der Anker für die Synchronisation, die Aufnahme neuer Computer in die Sync-Gruppe, die Anmeldung über Pass-through Authentication und der
Abgleich von Geräten.

## Set-UpnMailAndProxy.ps1

Stellt `userPrincipalName`, `mail` und `proxyAddresses` auf eine neue Domäne um – oder gleicht
den UPN an die vorhandene Mailadresse an. Der eigentliche Wert liegt im Ablauf: **vier Modi, die
nacheinander laufen, mit Rückweg.**

```powershell
.\Set-UpnMailAndProxy.ps1 -Mode CreateInput -SearchBase 'OU=Users,DC=example,DC=com' -OutputCsvPath .\kandidaten.csv
.\Set-UpnMailAndProxy.ps1 -Mode Plan    -InputCsvPath .\kandidaten.csv -TargetDomain 'neu.example.com' -PlanCsvPath .\plan.csv
.\Set-UpnMailAndProxy.ps1 -Mode Apply   -PlanCsvPath .\plan.csv -StateCsvPath .\zustand.csv
.\Set-UpnMailAndProxy.ps1 -Mode Restore -StateCsvPath .\zustand.csv
```

| Modus | Was passiert |
|---|---|
| `CreateInput` | Kandidaten auswählen und als CSV ablegen (optional) |
| `Plan` | **Nur lesen.** Berechnet, was sich ändern würde, und schreibt den Plan als CSV |
| `Apply` | Wendet einen Plan an und schreibt dabei den Vorzustand in eine Zustands-CSV |
| `Restore` | Macht eine Zustands-CSV rückgängig |

Weitere Schalter: `-Scope` (`Both`, `UpnOnly`, `MailOnly`), `-UpnMode` (`Suffix` setzt eine neue
Domäne, `MatchMail` zieht den UPN auf die Mailadresse nach), `-LdapFilter` zum Eingrenzen und
`-SkipAdWideCollisionCheck`, wenn die Prüfung auf schon vergebene Namen in einem großen
Verzeichnis zu lange dauert.

Der Plan ist eine gewöhnliche CSV: Man kann Zeilen löschen, bevor man ihn anwendet. Damit lässt
sich eine Umstellung in kontrollierten Wellen fahren.

## Get-ImmutableIdForUpn.ps1

Beantwortet die Frage, die bei jedem Sync-Problem kommt: *Welcher Anker gilt für diesen
Benutzer?*

```powershell
.\Get-ImmutableIdForUpn.ps1 -PickOU
.\Get-ImmutableIdForUpn.ps1 -OU 'OU=Berlin,DC=example,DC=com' -OutFile .\anker.csv
.\Get-ImmutableIdForUpn.ps1 -OU '...' -IncludeAnchorDetails
```

Ohne `-OU` öffnet `-PickOU` eine Mehrfachauswahl. Standardmäßig wird ermittelt, welcher Anker
tatsächlich greift – `ms-DS-ConsistencyGuid`, wenn gesetzt, sonst `objectGUID`. Mit
`-ForceConsistencyGuid` bzw. `-ForceObjectGuid` lässt sich das eine oder andere erzwingen, mit
`-IncludeAnchorDetails` werden beide Werte samt Herkunft ausgegeben. `-Server` wählt einen
bestimmten Domänencontroller.

## Get-PTAAuthEvents.ps1

Zeigt, was der Pass-through-Authentication-Agent tatsächlich verarbeitet hat – gelesen aus dem
Sicherheitsprotokoll des Agent-Servers, gefiltert auf
`AzureADConnectAuthenticationAgentService.exe`, mit lesbaren Statustexten statt roher Codes.

```powershell
.\Get-PTAAuthEvents.ps1
.\Get-PTAAuthEvents.ps1 -Hours 24 -MaxEvents 500
```

Auf dem Server ausführen, auf dem der Agent läuft. Standard sind die letzte Stunde und 50
Ereignisse.

## Add-NewComputerToGroup.ps1

Nimmt neu angelegte Computerkonten automatisch in eine AD-Gruppe auf – ausgelöst durch das
Security-Event 4741 (Scheduled Task mit Event-Trigger, kein Polling). Gedacht für Umgebungen, in
denen eine Gruppe (Standard `SYNC-Devices-to-ENTRA`) bestimmt, welche Geräte nach Entra ID
synchronisiert werden: Ohne Aufnahme in die Gruppe bleibt ein neuer Computer in der Cloud unsichtbar.
Das Skript automatisiert nur diese Aufnahme; Scoping und Sync-Konfiguration bleiben außerhalb.

```powershell
.\Add-NewComputerToGroup.ps1 -CheckPol      # erzeugt die Audit-Policy das Event 4741?
.\Add-NewComputerToGroup.ps1 -CreateTask    # Setup: fragt Zielgruppe und OUs ab, delegiert, legt Task an, testet
.\Add-NewComputerToGroup.ps1 -RemoveGmsa    # früher angelegtes gMSA samt Rechten aufräumen
```

- Event 4741 entsteht nur auf dem DC, der das Konto anlegt → Task auf **jedem** DC einrichten.
- Der Task läuft als SYSTEM; das Computerkonto des DC bekommt Schreibrecht auf `member` der Gruppe.
  Alternativ `-UseGmsa` (braucht KDS-Root-Key und „Log on as a batch job“).
- `-OuDn "DN1;DN2"` beschränkt auf Computer aus diesen OUs (inkl. Unter-OUs); Trenner `;`, da DNs
  Kommas enthalten. Geprüft wird der Ort zum Zeitpunkt des Events.
- Der Trigger reicht den Kontonamen per `ValueQueries` durch; das große Security-Log wird nicht
  durchsucht. gMSAs lösen ebenfalls 4741 aus und werden übersprungen.
- Log: `%ProgramData%\ADWeb\Add-NewComputerToGroup.log`

## Nicht hier: DeviceSyncer

Das Übertragen von Computerzertifikaten aus AD in die `alternativeSecurityIds` der Entra-Geräte
hat ein eigenes Repo: **[azitc-ac/DeviceSyncer](https://github.com/azitc-ac/DeviceSyncer)** –
dort mit Installationsskript, AD-Vorbereitung, Konfigurationsdatei und den Vorstufen im
`PoC`-Ordner. Es schließt die Lücke, die Entra Cloud Sync für Umgebungen ohne Entra Connect Sync
lässt.

## Voraussetzungen

Windows PowerShell 5.1. `Set-UpnMailAndProxy` und `Get-ImmutableIdForUpn` brauchen das Modul
`ActiveDirectory`, `DeviceSyncer` zusätzlich `Microsoft.Graph` und `Out-GridView`.
`Get-PTAAuthEvents` läuft auf dem Agent-Server und braucht Leserecht auf dem Sicherheitsprotokoll.
`Add-NewComputerToGroup` läuft als Administrator auf jedem DC (AD-DS-Rolle, Audit „Computer Account Management“).
