# ad-entra-dirsync-tools

Werkzeuge rund um Identitäten: Active Directory on-premises, Entra ID und die Synchronisation
dazwischen. Ein Ordner je Bereich, jedes Skript für sich lauffähig – keine gemeinsame Laufzeit,
keine Installation.

| Ordner | Werkzeug | Kurz |
|---|---|---|
| [AD](AD/) | `Manage-ADGroupMembers.ps1` | Gruppenmitglieder pflegen – Oberfläche mit Änderungserkennung |
| [Entra](Entra/) | `New-AcsEmailRelay.ps1` | Azure Communication Services als SMTP-Relay aufbauen, samt Setup-Doku |
| [DirSync](DirSync/) | `Set-UpnMailAndProxy.ps1` | UPN, mail und proxyAddresses auf eine neue Domäne umstellen – mit Rückweg |
| | `Get-ImmutableIdForUpn.ps1` | Welcher Anker gilt je Benutzer: ObjectGUID oder ConsistencyGuid |
| | `Get-PTAAuthEvents.ps1` | Anmeldungen über Pass-through Authentication im Klartext |
| | `DeviceSyncer.ps1` | AD-Computerzertifikate zum Entra-Gerät übertragen |
| [Vorlagen](Vorlagen/) | drei Skripte | Fertige Logik mit festen Werten – vor dem Lauf anpassen |

## Warum diese drei Bereiche zusammen

Die Trennung zwischen „AD" und „Entra" hält in der Praxis nicht: Eine UPN-Umstellung ist eine
AD-Änderung, die nur wegen der Synchronisation stattfindet. Der ImmutableID-Anker ist ein
AD-Attribut, das nur in der Cloud eine Bedeutung hat. Pass-through Authentication läuft auf einem
Server im AD und entscheidet über Cloud-Anmeldungen. Deshalb liegt alles, was zwischen den
Welten vermittelt, in `DirSync` – und nur was wirklich nur eine Seite betrifft, in `AD` oder
`Entra`.

## Voraussetzungen

Windows PowerShell 5.1. Je nach Werkzeug zusätzlich das Modul `ActiveDirectory` (RSAT),
`Microsoft.Graph`, `Az` oder die `az`-CLI – steht jeweils im Kopf des Skripts und in der README
des Ordners.

## Vorlagen gegen Werkzeuge

In `AD`, `Entra` und `DirSync` liegt nur, was sich über Parameter steuern lässt und ohne Eingriff
in den Code läuft. Skripte mit fest eingetragenen Pfaden, Domänen oder Tenants stehen in
`Vorlagen` – sie sind nicht weniger wert, aber man muss sie vor dem Lauf lesen und anpassen.

## Lizenz

MIT, soweit in den einzelnen Ordnern nicht anders angegeben.
