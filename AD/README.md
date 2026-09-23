# AD

Werkzeuge, die nur Active Directory on-premises betreffen.

## Invoke-ADAssessment.ps1

Nimmt eine Domäne auf und schreibt einen HTML-Bericht über Gesundheit, Sicherheit und Hygiene –
**rein lesend**. `dcdiag` und `repadmin` werden nur abgefragt, nichts wird verändert.

```powershell
.\Invoke-ADAssessment.ps1
.\Invoke-ADAssessment.ps1 -OutputPath D:\Berichte\Kunde -InactiveDays 180
```

`-InactiveDays` (Standard 90) legt fest, ab wann ein Konto als inaktiv gilt; ohne `-OutputPath`
landet der Bericht in einem Ordner mit Zeitstempel im aktuellen Verzeichnis.

Gedacht als schlanke Vorstufe zu den großen Werkzeugen (Purple Knight, ADxRay, BloodHound,
Locksmith, GPOZaurr): Es liefert in wenigen Minuten den Überblick, mit dem sich entscheiden lässt,
wo ein tieferer Blick nötig ist. Für Übernahmen und Erstaufnahmen.

Ausführen mit forstweiten Leserechten, am besten auf einem DC oder Verwaltungshost mit RSAT.

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
