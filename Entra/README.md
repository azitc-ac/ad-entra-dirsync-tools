# Entra

Werkzeuge, die nur Entra ID und angrenzende Azure-Dienste betreffen.

## New-AcsEmailRelay.ps1

Baut einen vollständigen SMTP-Relay über **Azure Communication Services** auf: Communication
Service, Email Service, eigene Domäne samt DNS-Einträgen, Absenderadresse und die
Entra-App-Registrierung für die SMTP-Anmeldung.

```powershell
.\New-AcsEmailRelay.ps1 -ResourceGroupName rg-comsvc -CommServiceName comsvc-edge `
    -EmailServiceName acs-email-edge -DomainName relay.example.com `
    -SmtpLoginUsername relay-login -CreateEntraApp -UseAzureDns
```

| Parameter | |
|---|---|
| `-ResourceGroupName`, `-CommServiceName`, `-EmailServiceName`, `-DomainName` | Pflicht |
| `-SmtpLoginUsername` | Pflicht – der Anmeldename für das Relay |
| `-CreateEntraApp` | legt die App-Registrierung samt Secret selbst an |
| `-EntraApplicationId`, `-EntraTenantId` | stattdessen eine vorhandene App verwenden |
| `-UseAzureDns` | trägt die Prüf- und SPF/DKIM-Einträge in eine vorhandene Azure-DNS-Zone ein |
| `-Location`, `-DataLocation` | Standard `global` und `Europe` |
| `-SenderUsername`, `-SenderDisplayName` | Standard `DoNotReply` |
| `-RoleName` | Rolle für den Relay-Zugriff, Standard `Communication and Email Service Owner` |

Voraussetzung ist eine angemeldete `az`-CLI mit gesetzter Subscription; die Erweiterung
`communication` wird bei Bedarf nachinstalliert.

## Die Setup-Doku daneben lesen

`ACS-Email-SMTP-Relay-Setup.md` gehört zum Skript und ist der eigentliche Wert dieses Ordners.
Sie hält die Stolperfallen fest, die beim ersten Aufbau Zeit gekostet haben:

- Die verbreitete Blog-Anleitung ist überholt.
- Der früher übliche zusammengesetzte Benutzername ist inzwischen **verboten**.
- PowerShell zerlegt `|` und `@` im Kommandozeilenkontext – die Anmeldedaten müssen entsprechend
  übergeben werden.
- **Doppelte SPF-Einträge brechen die Zustellung**, ohne dass der Dienst es meldet.
- Eigene Rollen sind an die Subscription gebunden.

Dazu Architekturübersicht, Kurzablauf, FAQ und Quellen.

## Voraussetzungen

Windows PowerShell 5.1, `az`-CLI (angemeldet), Rechte zum Anlegen von Ressourcen in der
Subscription und – für `-CreateEntraApp` – zum Registrieren von Anwendungen im Tenant.
