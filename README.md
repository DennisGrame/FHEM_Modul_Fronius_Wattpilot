# FHEM Modul: 72_Wattpilot.pm - Benutzerhandbuch

Dieses Dokument beschreibt die Installation und Einrichtung des Fronius Wattpilot Moduls für FHEM. Das Modul ermöglicht die Steuerung der Wallbox über das lokale Netzwerk via WebSocket.

## 1. Voraussetzungen (System & Perl Module)

Damit das Modul funktioniert, müssen auf dem Server (Raspberry Pi, PC, etc.), auf dem FHEM läuft, einige Perl-Zusatzmodule installiert sein. Das Modul nutzt modernere Verschlüsselung (PBKDF2), die nicht immer standardmäßig installiert ist.

### Benötigte Perl-Pakete

* `JSON`
* `Crypt::PBKDF2`
* `Digest::SHA`
* `MIME::Base64`

### Installation der Pakete (Debian/Raspbian/Ubuntu)

Führen Sie folgende Befehle im Terminal aus:

```bash
sudo apt-get update
sudo apt-get install libjson-perl libdigest-sha-perl libmime-base64-perl
```

Für `Crypt::PBKDF2` (oft nicht als apt-Paket verfügbar) nutzen Sie am besten cpanminus:

```bash
sudo apt-get install cpanminus
sudo cpanm Crypt::PBKDF2
```

## 2. Installation des Moduls

1. Laden Sie die Datei `72_Wattpilot.pm` herunter.
2. Kopieren Sie die Datei in das FHEM-Installationsverzeichnis, genauer in den Ordner `FHEM`.
    * Standardpfad (Linux): `/opt/fhem/FHEM/`
    * Beispielbefehl: `cp 72_Wattpilot.pm /opt/fhem/FHEM/`
3. Setzen Sie die korrekten Berechtigungen (optional, aber empfohlen):

    ```bash
    sudo chown fhem:dialout /opt/fhem/FHEM/72_Wattpilot.pm
    sudo chmod 644 /opt/fhem/FHEM/72_Wattpilot.pm
    ```

4. Starten Sie FHEM neu (`shutdown restart` in FHEM eingeben) oder laden Sie das Modul neu mit `reload 72_Wattpilot`.

## 3. Einrichtung in FHEM (Definition)

Um die Wallbox in FHEM einzubinden, legen Sie ein neues "Device" an.

### Syntax

```text
define <Name> Wattpilot <IP-Adresse> <Passwort> [Seriennummer]
```

* **<Name>**: Ein Name für das Gerät in FHEM (z.B. `wallbox` oder `meinWattpilot`).
* **<IP-Adresse>**: Die lokale IP-Adresse des Wattpilot im Netzwerk (z.B. `192.168.178.185`).
* **<Passwort>**: Das Passwort für den Wattpilot (das gleiche wie in der App).
* **[Seriennummer]** (Optional): Die Seriennummer der Box. Wenn weggelassen, versucht das Modul sie automatisch auszulesen.

### Beispiel

Geben Sie dies in die FHEM Kommandozeile ein:

```text
define wallbox Wattpilot 192.168.178.185 meinGeheimesPasswort
```

## 4. Funktionen & Befehle (Steuerung)

Sobald das Gerät verbunden ist (Status `connected`), können Sie es mit dem `set` Befehl steuern.

### Ladung Starten / Stoppen

Startet oder stoppt den Ladevorgang manuell.

```text
set wallbox Laden_starten Start
set wallbox Laden_starten Stop
```

### Stromstärke ändern (Ampere)

Legt den Ladestrom in Ampere fest (zwischen 6A und 32A).

```text
set wallbox Strom 16
```

Tipp: In der FHEM Oberfläche erscheint hierfür oft ein Slider.

### Modus ändern

Wechselt den Betriebsmodus der Wallbox.

```text
set wallbox Modus Eco
set wallbox Modus NextTrip
set wallbox Modus Default
```

### Next Trip Zeit einstellen

Setzt die gewünschte Uhrzeit für den "Next Trip" Modus.

```text
set wallbox Zeit_NextTrip 07:30
```

Format: `hh:mm`

## 5. Konfiguration (Attribute)

Sie können das Verhalten des Moduls über "Attribute" anpassen.

### `interval` (in Sekunden)

Legt fest, wie oft **hochfrequente Messwerte** (Spannung, Leistung, aktueller Strom) aktualisiert werden.

* Standard: `0` (Jede Änderung wird sofort angezeigt -> kann das Log füllen "Spam").
* Empfehlung: `10` oder `60`.
* *Hinweis:* Wichtige Änderungen (Ladevorgang startet, Auto angesteckt) werden immer **sofort** angezeigt, unabhängig vom Intervall.

### `update_while_idle` (0 oder 1)

Steuert, ob Messwerte aktualisiert werden, wenn das Auto **nicht** lädt.

* `0` (Standard): Wenn nicht geladen wird, werden Spannung/Leistung nicht aktualisiert, um Systemlast zu sparen (da meistens eh 0).
* `1`: Aktualisiert Werte auch im Leerlauf (z.B. zur Fehlersuche oder um Netzspannung zu überwachen). Greift nur in Kombination mit dem `interval`.

### `disable` (0 oder 1)

Deaktiviert das Modul komplett.

* `0` (Standard): Modul ist aktiv und verbindet sich.
* `1`: Modul wird deaktiviert, die Verbindung getrennt und keine neuen Verbindungsversuche unternommen. Nützlich bei Wartungsarbeiten.

### `verbose` (0 bis 5)

Steuert die Ausführlichkeit der Log-Einträge im FHEM Logfile.

* `1`: Nur Fehler.
* `2`: Wichtige Ereignisse (z.B. Login erfolgreich).
* `3`: Protokolliert gesendete Befehle.
* `4`: Protokolliert empfangene Daten vom Wattpilot.
* `5`: Debugging (sehr viel Text).

## 6. Readings (Messwerte)

Das Modul stellt folgende Werte ("Readings") zur Verfügung:

| Reading | Beschreibung |
| :--- | :--- |
| `state` | Verbindungsstatus (initialized, connected, auth_failed, disabled). |
| `CarState` | Status des Autos (Idle, Charging, WaitCar, Complete). |
| `power` | Aktuelle Gesamtleistung in Watt. |
| `EnergyTotal` | Gesamter Energiezähler in kWh. |
| `Voltage_L1..3` | Spannung auf den 3 Phasen in Volt. |
| `Current_L1..3` | Strom auf den 3 Phasen in Ampere. |
| `Strom` | Die aktuell im Wattpilot eingestellte Stromgrenze (Ampere). |
| `Laden_starten` | Status der manuellen Ladesteuerung (Start/Stop). |
| `Modus` | Aktueller Lademodus (Eco/Default/NextTrip). |
| `Zeit_NextTrip` | Eingestellte Uhrzeit für Next Trip (Format hh:mm). |
| `Energie_seit_Anstecken` | Geladene Energie in Wh seit das Auto angesteckt wurde. |

## 7. Fehlerbehebung

* **Status bleibt auf `initialized` oder `disconnected`**:
  * Prüfen Sie die IP-Adresse. Kann der FHEM-Server die IP anpingen?
  * Sind FHEM und Wattpilot im gleichen Netzwerk? (Oft Probleme bei Gast-Netzwerken).
* **Log zeigt "Authentication Failed"**:
  * Prüfen Sie das Passwort in der Definition (`defmod wallbox ...`).
* **Perl-Fehler im Log (`Can't locate Crypt/PBKDF2.pm`)**:
  * Die Voraussetzungen (Schritt 1) wurden nicht erfüllt. Installieren Sie das fehlende Perl-Modul nach.
