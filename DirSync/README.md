# DirSync

Alles, was zwischen Active Directory und Entra ID vermittelt: die Umstellung von Anmeldenamen,
der Anker für die Synchronisation, die Anmeldung über Pass-through Authentication und der
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
