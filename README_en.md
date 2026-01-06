# FHEM Module: 72_Wattpilot.pm - User Guide

This document describes the installation and configuration of the Fronius Wattpilot module for FHEM. The module allows control of the Wallbox over the local network via WebSocket.

## 1. Prerequisites (System & Perl Modules)

For the module to work, some additional Perl modules must be installed on the server (Raspberry Pi, PC, etc.) running FHEM. The module uses modern encryption (PBKDF2), which is not always installed by default.

### Required Perl Packages

* `JSON`
* `Crypt::PBKDF2`
* `Digest::SHA`
* `MIME::Base64`

### Installing Packages (Debian/Raspbian/Ubuntu)

Run the following commands in the terminal:

```bash
sudo apt-get update
sudo apt-get install libjson-perl libdigest-sha-perl libmime-base64-perl
```

For `Crypt::PBKDF2` (often not available as an apt package), it is best to use cpanminus:

```bash
sudo apt-get install cpanminus
sudo cpanm Crypt::PBKDF2
```

## 2. Installing the Module

1. Download the file `72_Wattpilot.pm`.
2. Copy the file to the FHEM installation directory, specifically into the `FHEM` folder.
    * Default path (Linux): `/opt/fhem/FHEM/`
    * Example command: `cp 72_Wattpilot.pm /opt/fhem/FHEM/`
3. Set the correct permissions (optional, but recommended):

    ```bash
    sudo chown fhem:dialout /opt/fhem/FHEM/72_Wattpilot.pm
    sudo chmod 644 /opt/fhem/FHEM/72_Wattpilot.pm
    ```

4. Restart FHEM (enter `shutdown restart` in FHEM) or reload the module with `reload 72_Wattpilot`.

## 3. Setup in FHEM (Definition)

To integrate the Wallbox into FHEM, create a new "Device".

### Syntax

```text
define <Name> Wattpilot <IP-Address> <Password> [Serial]
```

* **<Name>**: A name for the device in FHEM (e.g., `wallbox` or `myWattpilot`).
* **<IP-Address>**: The local IP address of the Wattpilot on the network (e.g., `192.168.178.185`).
* **<Password>**: The password for the Wattpilot (the same as in the App).
* **[Serial]** (Optional): The serial number of the box. If omitted, the module attempts to read it automatically.

### Example

Enter this into the FHEM command line:

```text
define wallbox Wattpilot 192.168.178.185 mySecretPassword
```

## 4. Functions & Commands (Control)

Once the device is connected (Status `connected`), you can control it using the `set` command.

### Start / Stop Charging

Manually starts or stops the charging process.

```text
set wallbox Laden_starten Start
set wallbox Laden_starten Stop
```

### Change Current (Amperes)

Sets the charging current in Amperes (between 6A and 32A).

```text
set wallbox Strom 16
```

Tip: In the FHEM interface, this often appears as a slider.

### Change Mode

Changes the operating mode of the Wallbox.

```text
set wallbox Modus Eco
set wallbox Modus NextTrip
set wallbox Modus Default
```

### Set Next Trip Time

Sets the desired time for the "Next Trip" mode.

```text
set wallbox Zeit_NextTrip 07:30
```

Format: `hh:mm`

## 5. Configuration (Attributes)

You can adjust the module's behavior via "Attributes".

### `interval` (in seconds)

Determines how often **high-frequency readings** (Voltage, Power, Current) are updated.

* Default: `0` (Every change is shown immediately -> can fill the log "Spam").
* Recommendation: `10` or `60`.
* *Note:* Important changes (charging starts, car plugged in) are always shown **immediately**, regardless of the interval.

### `update_while_idle` (0 or 1)

Controls whether readings are updated when the car is **not** charging.

* `0` (Default): If not charging, Voltage/Power are not updated to save system load (since mostly 0).
* `1`: Updates values even when idle (e.g., for troubleshooting or monitoring grid voltage). Only applies in combination with `interval`.

### `disable` (0 or 1)

Completely disables the module.

* `0` (Default): Module is active and connects.
* `1`: Module is deactivated, connection is closed, and no new connection attempts are made. Useful during maintenance.

### `verbose` (0 to 5)

Controls the verbosity of log entries in the FHEM log file.

* `1`: Errors only.
* `2`: Important events (e.g., login successful).
* `3`: Logs sent commands.
* `4`: Logs received data from Wattpilot.
* `5`: Debugging (lots of text).

## 6. Readings (Values)

The module provides the following values ("Readings"):

| Reading | Description |
| :--- | :--- |
| `state` | Connection status (initialized, connected, auth_failed, disabled). |
| `CarState` | Status of the car (Idle, Charging, WaitCar, Complete). |
| `power` | Current total power in Watts. |
| `EnergyTotal` | Total energy counter in kWh. |
| `Voltage_L1..3` | Voltage on the 3 phases in Volts. |
| `Current_L1..3` | Current on the 3 phases in Amperes. |
| `Strom` | The current limit currently set in Wattpilot (Amperes). |
| `Laden_starten`| Status of manual charging control (Start/Stop). |
| `Modus` | Current charging mode (Eco/Default/NextTrip). |
| `Zeit_NextTrip` | Set time for Next Trip (Format hh:mm). |

## 7. Troubleshooting

* **Status remains `initialized` or `disconnected`**:
  * Check the IP address. Can the FHEM server ping the IP?
  * Are FHEM and Wattpilot on the same network? (Often issues with Guest networks).
* **Log shows "Authentication Failed"**:
  * Check the password in the definition (`defmod wallbox ...`).
* **Perl Error in Log (`Can't locate Crypt/PBKDF2.pm`)**:
  * The prerequisites (Step 1) were not met. Install the missing Perl module.
