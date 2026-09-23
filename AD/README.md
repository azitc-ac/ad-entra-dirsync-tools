# AD

Werkzeuge, die nur Active Directory on-premises betreffen.

## Nicht hier: Invoke-ADAssessment

Die read-only Bestandsaufnahme einer Domäne mit HTML-Bericht hat ein eigenes Repo:
**[azitc-ac/Invoke-ADAssessment](https://github.com/azitc-ac/Invoke-ADAssessment)** – dort liegt
sie zusammen mit fünf weiteren Prüfskripten (`Test-LdapsBind`, `Test-LdapsRevocation`,
`Get-LdapBindMetric`, `Get-DcMemoryPressure`, `Get-DnsStaleRecords`).

## Delegate-ADUserAdmin.ps1

Vergibt Rechte zur Benutzerverwaltung auf einer OU – über `dsacls.exe`, mit `-WhatIf`.
Nimmt einem die Arbeit ab, die richtigen Berechtigungsausdrücke und Vererbungsschalter
(`/I:S`, `/I:T`) von Hand zusammenzusetzen, und macht die vergebenen Rechte nachvollziehbar.

## Manage-ADGroupMembers.ps1

Oberfläche zum Pflegen der Mitglieder einer AD-Gruppe – besonders für den Fall, dass eine Liste
von Benutzern aus einer Tabelle kommt und gegen den Ist-Stand abgeglichen werden soll.

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\Manage-ADGroupMembers.ps1
```

**Ablauf:** Zielgruppe über „AD-Gruppe suchen" wählen (Platzhalter `*` zeigt alle) oder eintippen
und „Gruppe einlesen". Links stehen die hinzuzufügenden Benutzer, rechts die aktuellen
Mitglieder. Die linke Liste füllt sich über „CSV laden" oder „Manuell hinzufügen"; mit
`Alle >` und `< Alle` wandern Einträge zwischen den Seiten.

**Warum das mehr ist als `Add-ADGroupMember`:** Beim Einlesen merkt sich das Skript den
Ausgangszustand der Gruppe. Beim Speichern werden daraus zwei Mengen gebildet – wirklich neue
Mitglieder und wirklich entfernte. Nur diese Differenz wird geschrieben. Wer aus Versehen
dieselbe Liste zweimal lädt, erzeugt keine doppelte Arbeit und keine unbeabsichtigten Entfernungen.

Eingelesene Namen werden gegen AD aufgelöst und mit dem vollständigen Namen angezeigt; was sich
nicht auflösen lässt, bleibt als Rohwert sichtbar und wird nicht stillschweigend übergangen.

## Voraussetzungen

Windows PowerShell 5.1 mit `-STA`, Modul `ActiveDirectory` (RSAT), Schreibrecht auf der
Zielgruppe.
