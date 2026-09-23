# Vorlagen

Diese Skripte tragen ihre Werte im Code: Pfade, Domänen, Tenants, OUs. Sie laufen **nicht**
ungelesen – man öffnet sie, passt die Werte oben an und führt sie dann aus. Der Wert liegt in der
Logik, nicht in der Bedienbarkeit.

| Skript | Was es tut | Was anzupassen ist |
|---|---|---|
| `import-ADUsersFromCSV_v4.ps1` | Legt Benutzer aus einer CSV an; die zu übernehmenden Attribute stehen als Liste im Kopf und lassen sich einzeln auskommentieren | `$csvPath`, `$OU`, `$importKeys` |
| `create-CustomOutboundRulesforCutover.ps1` | Erzeugt eigene Outbound-Regeln in Entra Connect für einen Domänen-Cutover – für eine oder mehrere Domänen | `$domains2cutover` |
| `convertTo-CloudUser.ps1` | Liest alle Benutzer samt ImmutableID aus und schreibt sie als CSV – Vorarbeit zum Umhängen synchronisierter Konten auf reine Cloud-Konten | `$cloudTenant`, `$outfile` |

## Warum sie hier und nicht im Papierkorb liegen

Ein Domänen-Cutover oder eine Konvertierung synchronisierter Konten passiert selten genug, dass
man die Feinheiten jedes Mal neu herausfinden müsste – und oft genug, dass es sich lohnt, sie
aufzuheben. Diese Dateien sind die Notizen aus dem letzten Mal, in ausführbarer Form.

Wer eines davon ein zweites Mal braucht, sollte überlegen, ob daraus ein richtiges Werkzeug mit
Parametern wird. Dann gehört es eine Ebene höher.
