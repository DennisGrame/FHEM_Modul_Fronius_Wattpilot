##############################################
#
# Steuerung für Fronius Wattpilot Wallbox via WebSocket API V2
#
# (c) 2026 Dennis Gramespacher
#
# This script is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# The GNU General Public License can be found at http://www.gnu.org/copyleft/gpl.html.
# A copy is found in the textfile GPL.txt and important notices to the license
# from the author is found in LICENSE.txt distributed with these scripts.
#
# Author: Dennis Gramespacher
#
# Quellen / Referenzen:
# 1. https://github.com/joscha82/wattpilot
# 2. https://wiki.fhem.de/wiki/Websocket
# 3. https://github.com/tim2zg/ioBroker.fronius-wattpilot
##############################################

package main;

use strict;
use warnings;
use DevIo;
use JSON;
use Digest::SHA qw(sha256_hex);
use Crypt::PBKDF2;
use MIME::Base64;
use Data::Dumper;

sub Wattpilot_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = \&Wattpilot_Define;
    $hash->{UndefFn}  = \&Wattpilot_Undefine;
    $hash->{SetFn}    = \&Wattpilot_Set;
    $hash->{GetFn}    = \&Wattpilot_Get;
    $hash->{AttrFn}   = \&Wattpilot_Attr;
    $hash->{ReadFn}   = \&Wattpilot_Read;
    $hash->{ReadyFn}  = \&Wattpilot_Ready;
    
    # Attribut-Liste:
    # interval: Schieberegler von 0 bis 300, Schrittweite 5 (Sekunden)
    # update_while_idle: Boolean (0/1) um Updates auch im Leerlauf zu erzwingen
    # defaultAmp: Standard-Stromstärke (kann als Slider dargestellt werden, z.B. 6-32A)
    $hash->{AttrList} = "debug:1,0 interval:slider,0,5,300 update_while_idle:0,1 defaultAmp:slider,6,1,32 disable:0,1 " . $readingFnAttributes;
}

sub Wattpilot_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t][ \t]*", $def);

    if(@a < 3) {
        return "Usage: define <name> Wattpilot <IP> <Password> [Serial]";
    }

    my $name = $a[0];
    my $ip = $a[2];
    my $password = $a[3];
    my $serial = $a[4] if (defined $a[4]);

    # DevIo WebSocket URL Format: ws:host:port/path
    $hash->{DeviceName} = "ws:$ip:80/ws";
    $hash->{PASSWORD} = $password;
    $hash->{SERIAL} = $serial;
    
    $hash->{STATE} = "Initialized";
    
    # WebSocket spezifische Header
    $hash->{header}{'User-Agent'} = 'FHEM';
    
    $modules{Wattpilot}{defptr}{$name} = $hash;
    
    # Starte Verbindungs-Timer (verzögerter Start)
    InternalTimer(gettimeofday()+2, "Wattpilot_Connect", $hash, 0);

    return undef;
}

sub Wattpilot_Undefine($$) {
    my ($hash, $name) = @_;
    
    RemoveInternalTimer($hash);
    DevIo_CloseDev($hash);
    
    delete $modules{Wattpilot}{defptr}{$name};
    return undef;
}

sub Wattpilot_Connect($) {
    my ($hash) = @_;
    
    return if(DevIo_IsOpen($hash));
    return if(Wattpilot_IsDisabled($hash->{NAME}));
    
    Log3 $hash, 3, "Wattpilot ($hash->{NAME}) - Connecting to $hash->{DeviceName}";
    
    # WebSocket in DevIo benötigt einen Callback für den asynchronen Verbindungsaufbau
    DevIo_OpenDev($hash, 0, undef, sub {
        my ($hash, $error) = @_;
        if($error) {
            Log3 $hash, 1, "Wattpilot ($hash->{NAME}) - Connection error: $error";
            return;
        }
        Wattpilot_DoInit($hash);
    });
}

sub Wattpilot_DoInit($) {
    my ($hash) = @_;
    # Hier könnten Initialisierungsbefehle gesendet werden, falls nötig
    return undef;
}

sub Wattpilot_Read($) {
    my ($hash) = @_;
    my $buf = DevIo_SimpleRead($hash);
    
    return "" if(!defined($buf));
    
    if($hash->{buffer}) {
        $buf = $hash->{buffer} . $buf;
        $hash->{buffer} = "";
    }

    # Behandle mehrere verkettete JSON-Nachrichten (z.B. json1}{json2)
    # Der Wattpilot sendet manchmal mehrere Pakete ohne Trennzeichen zusammen.
    $buf =~ s/}\s*{/}\n{/g;
    
    my @messages = split(/\n/, $buf);
    
    foreach my $msg (@messages) {
        # Prüfe, ob die Nachricht wie ein vollständiges JSON-Objekt aussieht
        if ($msg =~ m/^{.*}$/) {
             Wattpilot_Parse($hash, $msg);
        } else {
             # Unvollständige Nachricht? Im Buffer für den nächsten Read speichern.
             # Hinweis: Einfaches Buffering. Sollte für die normale JSON-Struktur ausreichen.
             $hash->{buffer} = $msg;
        }
    }
}

sub Wattpilot_Parse($$) {
    my ($hash, $msg) = @_;
    my $name = $hash->{NAME};
    
    my $json = eval { decode_json($msg) };
    if($@) {
        Log3 $name, 1, "Wattpilot ($name) - JSON Error: $@ - Msg: $msg";
        return;
    }
    
    my $type = $json->{type};
    Log3 $name, 4, "Wattpilot ($name) - Received type: $type";
    
    if ($type eq 'hello') {
        $hash->{SERIAL} = $json->{serial} if (!$hash->{SERIAL}); # Seriennummer übernehmen falls fehlt
        $hash->{VERSION} = $json->{version};
        readingsSingleUpdate($hash, "version", $json->{version}, 1);
        Log3 $name, 4, "Wattpilot ($name) - Hello received from Serial: $json->{serial}";
    } elsif ($type eq 'authRequired') {
        Log3 $name, 4, "Wattpilot ($name) - Auth Required";
        Wattpilot_SendAuth($hash, $json);
    } elsif ($type eq 'authSuccess') {
        Log3 $name, 2, "Wattpilot ($name) - Authentication Successful";
        readingsSingleUpdate($hash, "state", "connected", 1);
    } elsif ($type eq 'authError') {
        Log3 $name, 1, "Wattpilot ($name) - Authentication Failed: " . ($json->{message} // "Unknown Error");
        readingsSingleUpdate($hash, "state", "auth_failed", 1);
        DevIo_CloseDev($hash);
    } elsif ($type eq 'fullStatus' || $type eq 'deltaStatus') {
        Wattpilot_UpdateReadings($hash, $json->{status});
    }
}

sub Wattpilot_UpdateReadings($$) {
    my ($hash, $status) = @_;
    my $name = $hash->{NAME};
    
    # Rate-Limiting Logik:
    # Einige Werte (wie 'nrg' - Spannung/Strom) aktualisieren sehr häufig (hochfrequent).
    # Andere (wie 'amp', 'car', 'frc') sind niederfrequent und kritisch für die UI.
    # Das Intervall wird NUR auf die hochfrequenten "Spam"-Werte angewendet.
    
    my $interval = AttrVal($name, "interval", 0);
    my $now = gettimeofday();
    my $last_update = $hash->{LAST_UPDATE} // 0;
    
    # Unterdrücke Spam-Werte, wenn Intervall noch nicht abgelaufen
    my $suppress_spammy = ($interval > 0 && ($now - $last_update < $interval));
    
    # Aktualisiere Zeitstempel nur, wenn wir diesmal updaten
    if (!$suppress_spammy) {
        $hash->{LAST_UPDATE} = $now;
    }
    
    readingsBeginUpdate($hash);
    
    # --- KRITISCHE / NIEDERFREQUENTE UPDATES (Immer aktualisieren) ---
    
    # Fahrzeug Status (Car State)
    if (defined $status->{car}) {
        my %CarStateMap = (0 => 'Unknown', 1 => 'Idle', 2 => 'Charging', 3 => 'WaitCar', 4 => 'Complete', 5 => 'Error');
        my $state = $CarStateMap{int($status->{car})} // "Unknown";
        readingsBulkUpdate($hash, "CarState", $state);
        
        # Speichere internen Status für Logik (Charging vs Not Charging)
        $hash->{helper}{car_state} = int($status->{car});
    }
    
    # Prüfe ob geladen wird (Status 2)
    my $is_charging = ($hash->{helper}{car_state} // 0) == 2;
    
    # Laden Starten/Stoppen (frc Status)
    if (defined $status->{frc}) {
        my $frc_val = $status->{frc};
        my $state = "Unknown";
        if ($frc_val == 0) { $state = "Start"; }
        elsif ($frc_val == 1) { $state = "Stop"; }
        else { $state = $frc_val; }
        readingsBulkUpdate($hash, "Laden_starten", $state);
    }
    
    # Nächste Fahrt Zeit (ftt)
    if (defined $status->{ftt}) {
        # Sekunden ab Mitternacht in hh:mm umrechnen
        my $secs = $status->{ftt};
        my $h = int($secs / 3600);
        my $m = int(($secs % 3600) / 60);
        readingsBulkUpdate($hash, "Zeit_NextTrip", sprintf("%02d:%02d", $h, $m));
    }
    
    # Stromstärke (amp) - Sollte immer sofort aktualisiert werden
    if (defined $status->{amp}) {
        readingsBulkUpdate($hash, "Strom", $status->{amp});
    }
    
    # --- RATENLIMITIERTE UPDATES (Hochfrequent) ---
    # Nur wenn NICHT unterdrückt UND (Ladung aktiv ODER update_while_idle gesetzt)
    
    my $update_while_idle = AttrVal($name, "update_while_idle", 0);
    
    my $process_nrg = 0;
    if (!$suppress_spammy) {
        if ($is_charging || $update_while_idle) {
             $process_nrg = 1;
        }
    }
    
    if ($process_nrg) {
        
        # Energie Gesamt (eto)
        if (defined $status->{eto}) {
             # Rundung auf 2 Nachkommastellen, Umrechnung Wh -> kWh wenn nötig (Hier Annahme: Rohwert durch 1000)
             readingsBulkUpdate($hash, "EnergyTotal", sprintf("%.2f", $status->{eto} / 1000));
        }

        # Energie seit Anstecken (wh)
        if (defined $status->{wh}) {
             readingsBulkUpdate($hash, "Energie_seit_Anstecken", sprintf("%.2f", $status->{wh}));
        }
        
        # Energie Details (nrg Array)
        if (defined $status->{nrg}) {
            my @nrg = @{$status->{nrg}};
            if (@nrg > 11) {
                readingsBulkUpdate($hash, "Voltage_L1", sprintf("%.2f", $nrg[0]));
                readingsBulkUpdate($hash, "Voltage_L2", sprintf("%.2f", $nrg[1]));
                readingsBulkUpdate($hash, "Voltage_L3", sprintf("%.2f", $nrg[2]));
                readingsBulkUpdate($hash, "Current_L1", sprintf("%.2f", $nrg[4]));
                readingsBulkUpdate($hash, "Current_L2", sprintf("%.2f", $nrg[5]));
                readingsBulkUpdate($hash, "Current_L3", sprintf("%.2f", $nrg[6]));
                readingsBulkUpdate($hash, "Power_L1", sprintf("%.2f", $nrg[7]));
                readingsBulkUpdate($hash, "Power_L2", sprintf("%.2f", $nrg[8]));
                readingsBulkUpdate($hash, "Power_L3", sprintf("%.2f", $nrg[9]));
                readingsBulkUpdate($hash, "power", sprintf("%.2f", $nrg[11])); # Gesamtleistung
            }
        }
    }

    readingsEndUpdate($hash, 1);
}

sub Wattpilot_SendAuth($$) {
    my ($hash, $json) = @_;
    my $name = $hash->{NAME};
    my $password = $hash->{PASSWORD};
    my $serial = $hash->{SERIAL};
    
    if (!$password || !$serial) {
        Log3 $name, 1, "Wattpilot ($name) - Missing Password or Serial for authentication";
        return;
    }

    my $token1 = $json->{token1};
    my $token2 = $json->{token2};

    # 1. PBKDF2 Password Hashing
    # Serial als Salt verwenden
    my $h_args = { sha_size => 512 };
    my $pbkdf2_obj = Crypt::PBKDF2->new(
        hash_class => 'HMACSHA2',
        hash_args => $h_args,
        iterations => 100000,
        output_len => 256
    );
    
    # Berechne rohen PBKDF2 Hash
    my $dk = $pbkdf2_obj->PBKDF2($serial, $password);
    
    # Base64-Encoding und auf 32 Bytes kürzen
    my $password_hash = substr(MIME::Base64::encode_base64($dk, ""), 0, 32);
    
    # Für Session-Signatur (HMAC) speichern
    $hash->{hashed_password} = $password_hash;

    # 2. Generiere Token3 (Zufalls-Nonce)
    my $random_bytes = '';
    for (my $i = 0; $i < 16; $i++) { $random_bytes .= chr(int(rand(256))); }
    my $token3 = unpack 'H*', $random_bytes;

    # 3. Berechne Hash1 = SHA256(token1 + password_hash)
    my $hash1_input = $token1 . $password_hash;
    my $hash1 = sha256_hex($hash1_input);

    # 4. Berechne Final Hash = SHA256(token3 + token2 + hash1)
    my $final_hash_input = $token3 . $token2 . $hash1;
    my $final_hash = sha256_hex($final_hash_input);

    my $auth_response = {
        type => "auth",
        token3 => $token3,
        hash => $final_hash
    };
    
    my $msg = encode_json($auth_response);
    Log3 $name, 3, "Wattpilot ($name) - Sending Auth Response";
    DevIo_SimpleWrite($hash, $msg, 0);
}

sub Wattpilot_Set($@) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    my $cmd = $a[1];
    my $val = $a[2];

    return "Device is disabled" if(Wattpilot_IsDisabled($name));
    
    if($cmd eq 'Laden_starten') {
        # Befehl 'frc': Force State. 0=Start, 1=Stop.
        return "Usage: set $name Laden_starten <Start|Stop>" if (!defined $val || $val !~ /^(Start|Stop)$/);
        my $frc_val = ($val eq 'Start') ? 0 : 1;
        Wattpilot_SendSecure($hash, "frc", int($frc_val));
    } elsif ($cmd eq 'Strom') {
        # früher amp
        return "Usage: set $name Strom <6-32>" if (!defined $val || $val !~ /^\d+$/);
        Wattpilot_SendSecure($hash, "amp", int($val));
    } elsif ($cmd eq 'Modus') {
        # früher mode
        return "Usage: set $name Modus <Default|Eco|NextTrip>" if (!defined $val);
        my %mode_map = ( 'Default' => 3, 'Eco' => 4, 'NextTrip' => 5 );
        return "Unknown mode $val" if (!exists $mode_map{$val});
        Wattpilot_SendSecure($hash, "lmo", $mode_map{$val});
    } elsif ($cmd eq 'Zeit_NextTrip') {
        # 'ftt' Befehl für NextTrip Zeit, Format hh:mm
        # API erwartet Sekunden ab Mitternacht
        return "Usage: set $name Zeit_NextTrip <hh:mm>" if (!defined $val || $val !~ /^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$/);
        my ($h, $m) = split(':', $val);
        my $seconds = ($h * 3600) + ($m * 60);
        Wattpilot_SendSecure($hash, "ftt", int($seconds));
    } else {
        return "Unknown argument $cmd, choose one of Laden_starten:Start,Stop Strom:slider,6,1,32 Modus:Default,Eco,NextTrip Zeit_NextTrip";
    }
    
    return undef;
}

sub Wattpilot_SendSecure($$$) {
    my ($hash, $key, $val) = @_;
    my $name = $hash->{NAME};
    
    if (!$hash->{hashed_password}) {
        Log3 $name, 1, "Wattpilot ($name) - Cannot send command, not authenticated.";
        return;
    }
    
    # Msg ID Zähler
    $hash->{msg_id} = 0 if (!defined $hash->{msg_id});
    $hash->{msg_id}++;
    my $requestId = $hash->{msg_id};

    my $payload = {
        type => "setValue",
        requestId => $requestId,
        key => $key,
        value => $val
    };
    
    # JSON Encoding des Payloads für die Signatur
    my $payload_str = encode_json($payload);
    
    # Berechne HMAC SHA256 mit hashed_password als Key
    my $hmac = Digest::SHA::hmac_sha256_hex($payload_str, $hash->{hashed_password});
    
    my $secure_msg = {
        type => "securedMsg",
        data => $payload_str,
        requestId => "${requestId}sm",
        hmac => $hmac
    };
    
    my $final_msg = encode_json($secure_msg);
    Log3 $name, 3, "Wattpilot ($name) - Sending Secure Msg: $final_msg";
    DevIo_SimpleWrite($hash, $final_msg, 0);
}

sub Wattpilot_Get($@) {
    my ($hash, @a) = @_;
    return undef;
}

sub Wattpilot_Ready($) {
    my ($hash) = @_;
    if($hash->{STATE} eq "disconnected") {
        return DevIo_OpenDev($hash, 1, undef, sub {
             my ($hash, $error) = @_;
             return if($error);
             Wattpilot_DoInit($hash);
         });
    }
    return 0;
}

sub Wattpilot_Attr(@) {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};
    
    # $cmd kann "set" oder "del" sein
    # $name ist der Gerätename, $attrName das Attribut, $attrVal der Wert
    
    if($attrName eq "disable") {
        if($cmd eq "set" && $attrVal eq "1") {
             DevIo_CloseDev($hash);
             readingsSingleUpdate($hash, "state", "disabled", 1);
        } elsif($cmd eq "del" || $attrVal eq "0") {
             readingsSingleUpdate($hash, "state", "disconnected", 1);
             InternalTimer(gettimeofday()+1, "Wattpilot_Connect", $hash, 0);
        }
    }

    if($attrName eq "interval") {
        # Hier könnte Logik stehen, falls das Intervall sofortige Aktionen erfordert
    }
    
    return undef;
}

sub Wattpilot_IsDisabled($) {
    my ($name) = @_;
    return AttrVal($name, "disable", 0);
}

1;

# Beginn der Commandref
=pod
=item device
=item summary Controls Fronius Wattpilot Wallbox
=item summary_DE Steuert die Fronius Wattpilot Wallbox

=begin html

<a name="Wattpilot"></a>
<h3>Wattpilot</h3>
<ul>
  <li>This module controls a Fronius Wattpilot Wallbox via WebSocket API V2.</li>
  <li>It supports reading status values, setting charging modes, and starting/stopping charging.</li>
  <br>
  <a name="Wattpilot-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Wattpilot &lt;IP-Address&gt; &lt;Password&gt; [&lt;Serial&gt;]</code>
    <br><br>
    Defines a Wattpilot device.<br>
    <b>&lt;IP-Address&gt;</b>: The local IP address of the Wattpilot (e.g. 192.168.1.50).<br>
    <b>&lt;Password&gt;</b>: The password for the Wallbox.<br>
    <b>&lt;Serial&gt;</b>: (Optional) The serial number. If not provided, it will be automatically retrieved upon first connection.<br>
  </ul>
  <br>
  <a name="Wattpilot-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; Laden_starten &lt;Start|Stop&gt;</code><br>
        Manually starts or stops charging (corresponds to 'frc' parameter).</li>
    <li><code>set &lt;name&gt; Strom &lt;6-32&gt;</code><br>
        Sets the charging current in Amperes (usually 6 to 32A).</li>
    <li><code>set &lt;name&gt; Modus &lt;Default|Eco|NextTrip&gt;</code><br>
        Changes the charging mode:<br>
        - <b>Default</b>: Standard charging<br>
        - <b>Eco</b>: Eco Mode (PV surplus)<br>
        - <b>NextTrip</b>: Scheduled charging for next trip</li>
    <li><code>set &lt;name&gt; Zeit_NextTrip &lt;hh:mm&gt;</code><br>
        Sets the planned departure time (only relevant for NextTrip mode).</li>
  </ul>
  <br>
  <a name="Wattpilot-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>interval &lt;seconds&gt;</code><br>
        Interval in seconds for updating high-frequency readings (Voltage, Current per phase). 0 = Disabled (Immediate updates). Default: 0.</li>
    <li><code>update_while_idle &lt;0|1&gt;</code><br>
        If 1, voltage and current values are updated even when idle (not charging) (respects the interval). Useful for debugging. Default: 0.</li>
    <li><code>defaultAmp &lt;value&gt;</code><br>
        Standard value for the ampere setting (primarily used to define the slider range in the frontend).</li>
    <li><code>disable &lt;0|1&gt;</code><br>
        Completely disables the module. 1 = Disabled (Disconnects), 0 = Active.</li>
  </ul>
  <br>
  <a name="Wattpilot-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>Energie_seit_Anstecken</code><br>
        Energy consumed in Wh since the car was connected.</li>
    <li><code>EnergyTotal</code><br>
        Total energy counter in kWh.</li>
    <li><code>power</code><br>
        Current total power in Watts.</li>
    <li><code>Voltage_L1..3</code><br>
        Voltage on phases 1-3.</li>
    <li><code>Current_L1..3</code><br>
        Current on phases 1-3.</li>
  </ul>
</ul>

=end html

=begin html_DE

<a name="Wattpilot"></a>
<h3>Wattpilot</h3>
<ul>
  <li>Dieses Modul dient zur Steuerung einer Fronius Wattpilot Wallbox über die WebSocket API V2.</li>
  <li>Es unterstützt das Auslesen von Statuswerten, Setzen von Lademodi und Starten/Stoppen der Ladung.</li>
  <br>
  <a name="Wattpilot-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Wattpilot &lt;IP-Addresse&gt; &lt;Passwort&gt; [&lt;Seriennummer&gt;]</code>
    <br><br>
    Definiert ein Wattpilot Device.<br>
    <b>&lt;IP-Addresse&gt;</b>: Die lokale IP-Adresse des Wattpiloten (z.B. 192.168.1.50).<br>
    <b>&lt;Passwort&gt;</b>: Das Passwort für die Wallbox.<br>
    <b>&lt;Seriennummer&gt;</b>: (Optional) Die Seriennummer. Wenn nicht angegeben, wird sie beim ersten Verbinden automatisch ermittelt.<br>
  </ul>
  <br>
  <a name="Wattpilot-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; Laden_starten &lt;Start|Stop&gt;</code><br>
        Startet oder Stoppt die Ladung manuell (entspricht 'frc' Parameter).</li>
    <li><code>set &lt;name&gt; Strom &lt;6-32&gt;</code><br>
        Setzt den Ladestrom in Ampere (meist 6 bis 32A).</li>
    <li><code>set &lt;name&gt; Modus &lt;Default|Eco|NextTrip&gt;</code><br>
        Ändert den Lademodus:<br>
        - <b>Default</b>: Standard-Laden<br>
        - <b>Eco</b>: Eco-Modus (PV-Überschuss)<br>
        - <b>NextTrip</b>: Geplantes Laden für nächste Fahrt</li>
    <li><code>set &lt;name&gt; Zeit_NextTrip &lt;hh:mm&gt;</code><br>
        Setzt die geplante Abfahrtszeit (nur relevant für NextTrip Modus).</li>
  </ul>
  <br>
  <a name="Wattpilot-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>interval &lt;sekunden&gt;</code><br>
        Intervall in Sekunden für die Aktualisierung von hochfrequenten Messwerten (Spannung, Strom pro Phase). 0 = Deaktiviert (Sofortige Updates). Default: 0.</li>
    <li><code>update_while_idle &lt;0|1&gt;</code><br>
        Wenn 1, werden auch im Leerlauf (nicht ladend) Spannungs- und Stromwerte aktualisiert (beachtet das Interval). Hilfreich zur Fehlersuche. Default: 0.</li>
    <li><code>defaultAmp &lt;wert&gt;</code><br>
        Standardwert für die Ampereeinstellung (dient primär zur Definition des Slider-Bereichs im Frontend).</li>
    <li><code>disable &lt;0|1&gt;</code><br>
        Deaktiviert das Modul komplett. 1 = Deaktiviert (Trennt Verbindung), 0 = Aktiv.</li>
  </ul>
  <br>
  <a name="Wattpilot-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>Energie_seit_Anstecken</code><br>
        Geladene Energie in Wh seit das Auto angesteckt wurde.</li>
    <li><code>EnergyTotal</code><br>
        Gesamter Energiezähler in kWh.</li>
    <li><code>power</code><br>
        Aktuelle Gesamtleistung in Watt.</li>
    <li><code>Voltage_L1..3</code><br>
        Spannung auf den 3 Phasen in Volt.</li>
    <li><code>Current_L1..3</code><br>
        Strom auf den 3 Phasen in Ampere.</li>
  </ul>
</ul>

=end html_DE

# Ende der Commandref
=cut
