# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

## [Unreleased]

### Hinzugefügt

- **NextTrip-Ladeenergie:** Neuer Befehl `set <name> Energie_NextTrip <kWh>` (0,1–200 kWh). Der Wert wird in Wh umgerechnet und als API-Parameter `fte` übertragen.
- **NextTrip-Reading:** `Energie_NextTrip` zeigt die vom Wattpilot über `fte` gemeldete Energiemenge in kWh an.
- **Fahrzeugverbrauch:** `Verbrauch_100km` zeigt den in der Wattpilot-App hinterlegten Verbrauch aus `cco` in kWh/100 km an.
- **Dokumentation:** Deutsche und englische README sowie API-Zuordnung um NextTrip-Funktionen ergänzt.

### Hinweise

- `Zeit_NextTrip` (`ftt`) und die Moduswahl (`lmo`) waren bereits vorhanden; diese Einträge sind keine neuen Funktionen.
- Für `Verbrauch_100km` ist kein eigener `set`-Befehl implementiert.

## [v1.2.0] - 2026-04-24

### Hinzugefügt

- **Wattpilot Flex Support:** Unterstützung für die neue Wattpilot Flex Generation durch Implementierung der `bcrypt`-Authentifizierung.
- **Sicherheit:** Das Passwort wird nun nicht mehr in der Definition, sondern separat über `set <name> Password <secret>` gesetzt und persistent (aber außerhalb der Konfigurationsdatei) gespeichert.
- **Authentifizierungs-Modus:** Neues Attribut `authHash` zur Auswahl des Verfahrens (`auto`, `pbkdf2`, `bcrypt`).
- **Erweiterte Messwerte:** Neue Readings für Einzelleistungen pro Phase (`Power_L1`, `Power_L2`, `Power_L3`) sowie die Firmware-Version (`version`) und das aktive Authentifizierungsverfahren (`authHashMode`).

### Geändert

- **Definition:** Die Syntax des `define`-Befehls hat sich geändert. Das Passwort ist kein Parameter mehr.

## [v1.1.1] - 2026-03-07


### Geändert

- **Performance:** Optimierung der PBKDF2-Kryptographie-Berechnung für den Login. Die angeforderte Hash-Länge wurde von 256 auf 24 Bytes reduziert, was zu einer um ca. 75 % schnelleren Hash-Block-Generierung führt. Für eine verbesserte Effizienz wird nun die native `PBKDF2_base64`-Methode genutzt.

## [v1.1.0] - 2026-01-26

### Hinzugefügt

- Das Reading `Energie_seit_Anstecken` wurde hinzugefügt.

## [v1.0.0] - 2026-01-06

### Hinzugefügt

- Erste Veröffentlichung (Initial Release).
