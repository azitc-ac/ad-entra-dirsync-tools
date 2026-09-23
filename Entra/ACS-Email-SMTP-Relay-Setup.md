# Azure Communication Services – Email/SMTP-Relay: Setup-Doku

Diese Doku hält fest, wie man einen ACS Communication Service für SMTP-Relay-Versand (z.B. für `Send-Notification` in `run-userHygieneProcess_cloud.ps1`) von Grund auf aufsetzt — inklusive aller Stolperfallen, die wir beim Aufbau des Test-Tenant-Setups (`comsvc-edge`, Tenant `zarenko.onmicrosoft.com`) getroffen haben. Das zugehörige Automatisierungsskript ist [New-AcsEmailRelay.ps1](New-AcsEmailRelay.ps1).

## Architektur / benötigte Ressourcen

```
Resource Group
 ├─ CommunicationService        (comsvc-edge)         → SMTP-Endpunkt smtp.azurecomm.net, Auth via Entra App
 │   └─ SmtpUsernames/<name>    (acs-emailsvc-edge)    → verknüpft Entra App ↔ SMTP-Login-Username
 └─ EmailService                (acs-email-edge)
     └─ Domains/<domain>        (example.com)     → DNS-verifizierte Absenderdomain
         └─ SenderUsernames/<n> (DoNotReply)            → erlaubte MailFrom-Adressen unter der Domain

Entra ID (Tenant-Ebene, unabhängig von Subscription!):
 └─ App Registration + Client Secret                   → Identität, mit der sich das Skript per SMTP AUTH anmeldet
     └─ RBAC-Rolle "Communication and Email Service Owner" auf der CommunicationService-Ressource
```

Die Entra-App-Registrierung liegt auf **Tenant-Ebene** und ist unabhängig von der Subscription — bei einem Subscription-Wechsel (wie bei uns) muss sie nicht neu angelegt werden, nur die RBAC-Rolle neu zugewiesen.

## Ablauf (Kurzfassung)

1. Resource Group anlegen
2. `CommunicationService`-Ressource anlegen
3. `EmailService`-Ressource + Custom Domain (`CustomerManaged`) anlegen
4. DNS-Verifizierungsrecords (Domain-TXT, SPF-TXT, DKIM-CNAME, DKIM2-CNAME) beim DNS-Provider eintragen
5. Verifizierung bei Azure anstoßen (Domain, SPF, DKIM, DKIM2)
6. Sender-Username (MailFrom-Adresse, z.B. `DoNotReply`) unter der Domain anlegen
7. Domain mit der `CommunicationService`-Ressource verknüpfen (`--linked-domains`)
8. Entra-App per RBAC-Rolle Zugriff auf die `CommunicationService`-Ressource geben
9. SMTP-Username-Ressource anlegen (verknüpft Entra-App ↔ SMTP-Login-Name)

Das automatisierte Skript [New-AcsEmailRelay.ps1](New-AcsEmailRelay.ps1) deckt 1–3, 6–9 komplett ab, sowie optional 4–5 wenn die Domain in Azure DNS liegt.

## Wichtige Stolperfallen (der Grund für diese Doku)

### 1. Die alte Blog-Anleitung ist veraltet
Ältere Anleitungen (z.B. der ursprüngliche Techcommunity-Blogpost "Send emails via SMTP relay with Azure Communication Services") beschreiben nur: RBAC-Rolle zuweisen, SMTP-Username wird automatisch aus `<ResourceName>.<AppId>.<TenantId>` berechnet. **Das funktioniert nicht mehr.** Microsoft hat inzwischen eine eigene Ressource **"SMTP Usernames"** eingeführt, die zusätzlich explizit angelegt werden muss — die reine Rollenzuweisung reicht nicht mehr aus.

### 2. Der berechnete Username-String ist jetzt sogar verboten
Versucht man, den SMTP-Login-Username selbst aus `<ResourceName>` + `<AppId>` + `<TenantId>` zusammenzusetzen (egal ob mit Punkt oder Pipe getrennt), lehnt die API das explizit ab:
```
The username format cannot be constructed from Entra credentials. '<acs resource name>|<GUID>|<GUID>' is an unallowed format.
```
→ Der `username` muss ein **frei gewählter String** sein (oder E-Mail-Format unter einer verlinkten Domain), z.B. `edge-relay-svc`. Er darf außerdem:
- nicht identisch mit dem Ressourcennamen der SmtpUsername-Ressource selbst sein ("username cannot be the same as the resource name")
- nicht mit einem bereits vergebenen Sender-Username kollidieren (z.B. `DoNotReply`, wenn das schon als MailFrom-Adresse existiert) → `"The username is not available"`

### 3. PowerShell zerlegt `|` und `@` im Kommandozeilen-Kontext
Beim Versuch, den (jetzt zwar verbotenen, aber ursprünglich vorgeschlagenen) Pipe-getrennten Username per `az communication smtp-username create --username "a|b|c"` zu übergeben, riss PowerShell den String an den `|`-Zeichen auseinander und interpretierte die Teile als eigene Befehle — auch mit Anführungszeichen und selbst über eine Variable (`$name = 'a|b|c'`). Grund: irgendeine Zwischenschicht (vermutlich ein PowerShell-Wrapper von `az`) baut die Argumente intern nochmal als String zusammen und parst dabei `|` neu.
→ **Workaround**: Werte mit Sonderzeichen nicht über CLI-Parameter, sondern über eine JSON-Datei + `az rest --body @datei.json` übergeben. Das Skript nutzt diesen Ansatz generell für den `username`-Wert der SmtpUsername-Ressource.

Ein alleinstehendes `@` (z.B. für DNS-Root-Records `-n @` oder Datei-Referenzen `--body @file.json`) muss in PowerShell **immer gequotet** werden (`"@"` bzw. `"@file.json"`), sonst versucht PowerShell, es als Splat-Operator zu interpretieren.

### 4. Doppelte SPF-Records brechen die Zustellung
Wenn die Zieldomain schon einen `v=spf1`-TXT-Record hat (z.B. für bestehenden Mailversand), darf **kein zweiter** `v=spf1`-Record hinzugefügt werden — laut RFC 7208 ist das ungültig (SPF-PermError) und beeinträchtigt **die gesamte** Mail-Zustellung der Domain, nicht nur die neue. Vor dem Hinzufügen immer prüfen, ob `include:spf.protection.outlook.com` schon in einem bestehenden SPF-Record enthalten ist — falls ja, ist nichts zu tun. Das Skript prüft das automatisch (`-UseAzureDns`).

### 5. Custom Roles sind subscription-gebunden
Falls beim ursprünglichen Setup eine **Custom Role** (statt einer eingebauten Rolle) für die RBAC-Zuweisung verwendet wurde, ist diese meist nur in der Subscription definiert, in der sie erstellt wurde. Bei einem Subscription-Wechsel (wie bei uns) schlägt die Zuweisung mit `Role '...' doesn't exist` fehl. **Empfehlung: die eingebaute Rolle `Communication and Email Service Owner` verwenden**, die existiert überall und erspart dieses Problem.

## FAQ

**Wie viele Absenderadressen (Sender Usernames / MailFrom-Adressen) kann ich pro Domain anlegen?**
Bis zu **100 SenderUsername/MailFrom-Ressourcen pro Domain** (offizielles Service-Limit). Zusätzliche Absenderadressen über den Standard-`DoNotReply@<domain>` hinaus benötigen laut Doku eigentlich vorher ein "higher than default sending limit" auf der Custom Domain (im Portal ist der "Add"-Button sonst ausgegraut) — per CLI/REST hat das Anlegen bei uns aber ohne vorherige Quota-Erhöhung funktioniert.

**Wie füge ich eine weitere Absenderadresse hinzu?**
```powershell
az communication email domain sender-username create `
    --domain-name example.com --email-service-name acs-email-edge -g rg-comsvc-edge `
    --sender-username Reports --username Reports --display-name "Reports"
```
Ergibt die Absenderadresse `reports@example.com`. Zum Entfernen: `sender-username delete` mit denselben Parametern (ohne `--username`/`--display-name`).

**Wie viele Domains kann ich mit einer Communication-Service-Ressource verknüpfen?**
Bis zu **100 verlinkte Domains** pro `CommunicationService`-Ressource (`--linked-domains` ist eine Liste).

**Wie viele SMTP-Authentifizierungsverbindungen sind erlaubt?**
Maximal **250 gleichzeitig authentifizierte SMTP-Verbindungen pro Subscription**.

**Wie viele Mails darf ich pro Minute/Stunde verschicken?**
Bei einer Custom Domain (Standard, ohne Quota-Erhöhung): **30/Minute, 100/Stunde**. Bei einer Azure-Managed-Domain (`donotreply@xxxx.azurecomm.net`) nur **5/Minute, 10/Stunde**, und dort sind **keine** höheren Limits möglich — nur Custom Domains sind für eine Quota-Erhöhung berechtigt. Erhöhungen laufen über einen [Quota-Increase-Request](https://learn.microsoft.com/en-us/azure/communication-services/concepts/email/email-quota-increase) und dauern bis zu 72h; Voraussetzung ist eine Fehlerquote < 1%.

**Weitere Größenlimits:** max. 50 Empfänger pro Mail, max. 10 MB Gesamtgröße (inkl. Anhänge, vor Base64), Anhänge > 10 MB nur per Support-Request bis 30 MB, größere Dateien besser per Blob-Storage-Link mit SAS-Token verschicken.

## Quellen
- [az communication | Microsoft Learn](https://learn.microsoft.com/en-us/cli/azure/communication?view=azure-cli-latest)
- [az communication email | Microsoft Learn](https://learn.microsoft.com/en-us/cli/azure/communication/email?view=azure-cli-latest)
- [az communication email domain | Microsoft Learn](https://learn.microsoft.com/en-us/cli/azure/communication/email/domain?view=azure-cli-latest)
- [az communication smtp-username | Microsoft Learn](https://learn.microsoft.com/en-us/cli/azure/communication/smtp-username?view=azure-cli-latest)
- [Set up SMTP authentication for sending emails | Microsoft Learn](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication)
- [Service limits for Azure Communication Services | Microsoft Learn](https://learn.microsoft.com/en-us/azure/communication-services/concepts/service-limits)
- [How to add and remove multiple email sender addresses | Microsoft Learn](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-multiple-senders)
- [Quota increase for email domains | Microsoft Learn](https://learn.microsoft.com/en-us/azure/communication-services/concepts/email/email-quota-increase)
