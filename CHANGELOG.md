# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

## [v1.1.1] - 2026-03-07

### Geändert

- **Performance:** Optimierung der PBKDF2-Kryptographie-Berechnung für den Login. Die angeforderte Hash-Länge wurde von 256 auf 24 Bytes reduziert, was zu einer um ca. 75 % schnelleren Hash-Block-Generierung führt. Für eine verbesserte Effizienz wird nun die native `PBKDF2_base64`-Methode genutzt.

## [v1.1.0] - 2026-01-26

### Hinzugefügt

- Das Reading `Energie_seit_Anstecken` wurde hinzugefügt.

## [v1.0.0] - 2026-01-06

### Hinzugefügt

- Erste Veröffentlichung (Initial Release).
