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

### Entwurfsgeschichte von Add-NewComputerToGroup

Warum das Skript so aussieht, wie es aussieht – inklusive der Sackgassen.

**Ausgangsfrage:** Neue Computerobjekte sollen ohne Polling in die Sync-Gruppe. Ein passendes
Ereignis gibt es: Security-Event **4741** („Computerkonto erstellt“). Es entsteht nur auf dem DC,
der das Konto angelegt hat – deshalb braucht jeder DC seinen eigenen Task. Voraussetzung ist die
Audit-Subkategorie „Computer Account Management“ (Success); `-CheckPol` prüft die *effektive*
Policy (`AuditQuerySystemPolicy`), nicht nur die Konfiguration.

**Erster Entwurf: Task als gMSA.** Idee: kein Passwort, minimale Rechte. Das Setup legte das gMSA
an (KDS-Root-Key, `PrincipalsAllowedToRetrieveManagedPassword`), gab ihm Schreibrecht auf `member`
der Gruppe und Leserecht aufs Security-Log (Event Log Readers) und versuchte, das Recht „Log on as
a batch job“ über die lokale Gruppe Performance Log Users (S-1-5-32-559) zu erteilen. Das Skript
prüft dieses Recht nur als **Hinweis** (`secedit /export /areas USER_RIGHTS`), es ändert keine GPO.

**Warum das gMSA aufgegeben wurde:** Der Task startete nie. Task Scheduler meldete 0x80070569,
das Security-Log Event 4625 mit Status 0xC000015B („Anmeldetyp nicht gewährt“). Geprüft war
dabei alles, was sich prüfen ließ: das gMSA stand per `tokenGroups` in der Gruppe, die Gruppe stand
in der `SeBatchLogonRight`-Liste (`secedit` und LSA-Abfrage), kein Eintrag in `SeDenyBatchLogonRight`.
**Die Ursache ist bis heute ungeklärt.** Die Vermutung „eine GPO überschreibt das lokale Recht“
trifft nur zu, wenn eine GPO dieses Recht überhaupt definiert – das war nicht belegt. Die Alternative,
das Recht über die Default Domain Controllers Policy an eine Gruppe zu vergeben, wurde erwogen und
verworfen (zu viel Eingriff für einen Hilfs-Task).

**Entscheidung:** Der Task läuft als **SYSTEM**. Das Schreibrecht auf `member` der Zielgruppe
bekommt das **Computerkonto des DC** (`DC7$`), per ACE auf der Gruppe. Damit gibt es kein
Passwort, kein KDS und kein Batch-Recht. Der Preis: Jeder Prozess als SYSTEM auf dem DC kann diese
Gruppe ändern – bei einem DC ohnehin der Fall. `-UseGmsa` bleibt als Option erhalten,
`-RemoveGmsa` räumt ein früher angelegtes gMSA samt Rechten auf (ACE, Gruppenmitgliedschaften,
Ordner-ACL; der KDS-Root-Key bleibt).

**Weitere Lehren, die im Code stecken:**
- **Event 4741 gibt es auch für gMSAs.** Das Skript prüft deshalb per `Get-ADObject` die
  objectClass `computer` und überspringt alles andere (frühere Meldung „Konto nicht gefunden“
  war irreführend).
- **Das Security-Log durchsuchen ist zu langsam.** Bei 4 GB / 5 Mio. Einträgen dauerte die
  4741-Suche 114 s. Der Trigger reicht deshalb `TargetUserName` per `ValueQueries` an den Task
  durch (`-ComputerSam "$(TargetUser)"`); das Skript prüft nach der Registrierung per
  `Export-ScheduledTask`, dass diese Definition wirklich im Task steht. Die Log-Suche bleibt nur als
  Nachhol-Fallback.
- **„Task lief“ heißt nicht „Task wirkt“.** `Test-TaskRun` wartet auf den echten Start und
  wertet die Ergebniscodes aus (0x41303 = noch nie gelaufen, 0x41301 = läuft, 0x80070569 =
  Anmeldetyp nicht gewährt). Der Selbsttest (`$(*`-Aufruf) prüft Log-Zugriff, OUs und
  Schreibrecht per Probe (vorhandenes Mitglied erneut hinzufügen). Das ist **kein** vollständiger
  Beweis; den liefert erst das erste echte neue Gerät (Logzeile `ADD <name>$ -> <Gruppe>`).
- **PowerShell-Fallen:** Variablennamen sind case-insensitiv (`$useGmsa` und `$UseGmsa` waren
  dieselbe Variable), `\"` ist kein Escape in PS-Strings, `.IsPresent` gibt es nur auf
  Switch-Parametern, Array-Parameter über `powershell -File` kommen als ein String an (daher
  `;` als Trenner bei `-OuDn`).
- **Security-Log verkleinern:** Die maximale Größe lässt sich per `wevtutil sl Security /ms:<Bytes>`
  senken; eine bereits größere Datei schrumpft erst beim Archivieren und Leeren
  (`wevtutil epl` / `wevtutil cl`), nicht durch die Einstellung allein.

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
