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
use Data::Dumper;

eval {
    require Crypt::Bcrypt;
    Crypt::Bcrypt->import(qw(bcrypt));
    1;
};


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
    $hash->{AttrList} = "debug:1,0 interval:slider,0,5,300 update_while_idle:0,1 defaultAmp:slider,6,1,32 disable:0,1 authHash:auto,pbkdf2,bcrypt " .
	$readingFnAttributes;
}

sub Wattpilot_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t][ \t]*", $def);

    if(@a < 3) {
        return "Usage: define <name> Wattpilot <IP> [Serial]";
    }

    my $name = $a[0];
    my $ip = $a[2];
    my $serial = $a[3] if (defined $a[3]);
	
	
    # DevIo WebSocket URL Format: ws:host:port/path
    $hash->{DeviceName} = "ws:$ip:80/ws";
    $hash->{SERIAL} = $serial;
    
	my $password = Wattpilot_GetPassword($hash);
	
    $hash->{STATE} = "Initialized";
    
    # WebSocket spezifische Header
    $hash->{header}{'User-Agent'} = 'FHEM';
    
    $modules{Wattpilot}{defptr}{$name} = $hash;
    
    # Starte Verbindungs-Timer (verzögerter Start) falls password verfügbar
	if (defined($password) && $password ne "") {
		readingsSingleUpdate($hash, "state", "connecting", 1);
		InternalTimer(gettimeofday()+2, "Wattpilot_Connect", $hash, 0);
	} else {
		readingsSingleUpdate($hash, "state", "password missing", 1);
	}
    return undef;
}

sub Wattpilot_Undefine($$) {
    my ($hash, $name) = @_;

	# delete password and hash
    Wattpilot_DeleteStoredSecrets($hash);
	
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
	
	Log3 $name, 5, "Wattpilot ($name) - JSON: " . Dumper($msg);
    
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
	
	if (defined $status->{lmo}) {
    my %mode_rev = (
        3 => 'Default',
        4 => 'Eco',
        5 => 'NextTrip',
    );

    my $mode_num  = $status->{lmo};
    my $mode_text = $mode_rev{$mode_num} // $mode_num;

    readingsBulkUpdate($hash, "Modus", $mode_text);
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
    my $name     = $hash->{NAME};
    my $password = Wattpilot_GetPassword($hash);
    my $serial   = $hash->{SERIAL};

    if (!$password || !$serial) {
        Log3 $name, 1, "Wattpilot ($name) - Missing Password or Serial for authentication";
        return;
    }

    my $mode = eval { Wattpilot_GetAuthHashMode($hash, $json) };
    if ($@) {
        Log3 $name, 1, "Wattpilot ($name) - Failed to determine auth mode: $@";
        return;
    }
    $hash->{helper}{authHashMode} = $mode;

    my $password_hash = eval {
        Wattpilot_DerivePasswordHash($hash, $password, $serial);
    };
    if ($@) {
        Log3 $name, 1, "Wattpilot ($name) - Password hash derivation failed ($mode): $@";
        readingsSingleUpdate($hash, "state", "auth_hash_failed", 1);
        return;
    }

    Wattpilot_SetStoredPasswordHash($hash, $password_hash);

    my $token1 = $json->{token1};
    my $token2 = $json->{token2};

    my $random_bytes = '';
    for (my $i = 0; $i < 16; $i++) {
        $random_bytes .= chr(int(rand(256)));
    }
    my $token3 = unpack 'H*', $random_bytes;

    my $hash1_input = $token1 . $password_hash;
    my $hash1       = sha256_hex($hash1_input);

    my $final_hash_input = $token3 . $token2 . $hash1;
    my $final_hash       = sha256_hex($final_hash_input);

    my $auth_response = {
        type   => "auth",
        token3 => $token3,
        hash   => $final_hash,
    };

    my $msg = encode_json($auth_response);
    Log3 $name, 3, "Wattpilot ($name) - Sending Auth Response using mode=$mode";
    DevIo_SimpleWrite($hash, $msg, 0);
	
	readingsSingleUpdate($hash, "authHashMode", $mode, 1);
}

sub Wattpilot_BcryptPasswordHash($$$) {
    my ($hash, $password, $serial) = @_;
    my $name = $hash->{NAME};

    die "Crypt::Bcrypt not installed"
      unless defined &bcrypt;

    my $cost = AttrVal($name, "authHashCost", 8);

    my $password_sha256 = sha256_hex($password);          # wie im Python-Beispiel
    my $salt_raw        = Wattpilot_BcryptSerialRawSalt($serial, 16);

    my $full = bcrypt($password_sha256, '2a', $cost, $salt_raw);

    Log3 $name, 5, "Wattpilot ($name) - bcrypt full=$full";

    # Erwartet: $2a$08$<22-char-salt><31-char-hash>
    $full =~ /^\$2[abxy]\$\d\d\$[\.\/A-Za-z0-9]{22}([\.\/A-Za-z0-9]{31})$/
      or die "Unexpected bcrypt output format";

    return $1;
}

sub Wattpilot_DerivePasswordHash($$$) {
    my ($hash, $password, $serial) = @_;
    my $mode = $hash->{helper}{authHashMode} // "pbkdf2";

    if ($mode eq "pbkdf2") {
        my $h_args = { sha_size => 512 };
        my $pbkdf2_obj = Crypt::PBKDF2->new(
            hash_class => 'HMACSHA2',
            hash_args  => $h_args,
            iterations => 100000,
            output_len => 24
        );

        return $pbkdf2_obj->PBKDF2_base64($serial, $password);
    }

    elsif ($mode eq "bcrypt") {
        return Wattpilot_BcryptPasswordHash($hash, $password, $serial);
    }

    die "Unsupported authHash mode: $mode";
}



sub Wattpilot_BcryptSerialRawSalt($$) {
    my ($serial, $length) = @_;

    die "Check serial - should be digits only"
      unless defined($serial) && $serial =~ /^\d+$/;

    my @vals = map { ord($_) - ord('0') } split //, $serial;
    die "Serial too long" if scalar(@vals) > $length;

    my @bytes = ((0) x ($length - scalar(@vals)), @vals);
    return pack('C*', @bytes);   # genau 16 Byte
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
	} elsif ($cmd eq 'Password') {
		return "Usage: set $name Password <secret>" if (!defined($a[2]) || $a[2] eq "");

		my $password = $a[2];
		my $key = "Wattpilot_" . $name . "_password";

		my $err = setKeyValue($key, $password);
		return "failed to store password: $err" if defined($err);

		my $hashkey = "Wattpilot_" . $name . "_passwordhash";
		setKeyValue($hashkey, undef);
		
	
		readingsSingleUpdate($hash, "state", "password stored", 1);
		
		RemoveInternalTimer($hash);
		DevIo_CloseDev($hash);
		InternalTimer(gettimeofday()+1, "Wattpilot_Connect", $hash, 0);
		
		return undef;
	} 
	else {
        return "Unknown argument $cmd, choose one of Password Laden_starten:Start,Stop Strom:slider,6,1,32 Modus:Default,Eco,NextTrip Zeit_NextTrip";
    }
    
    return undef;
}

sub Wattpilot_SendSecure($$$) {
    my ($hash, $key, $val) = @_;
    my $name = $hash->{NAME};
    
    my $stored_hash = Wattpilot_GetPasswordHash($hash);
    if (!$stored_hash) {
        Log3 $name, 1, "Wattpilot ($name) - Cannot send command, missing stored password hash.";
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
    my $hmac = Digest::SHA::hmac_sha256_hex($payload_str, $stored_hash);
    
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
			 my $password = Wattpilot_GetPassword($hash);
			 if (defined($password) && $password ne "") {
				 readingsSingleUpdate($hash, "state", "disconnected", 1);
				 InternalTimer(gettimeofday()+1, "Wattpilot_Connect", $hash, 0);
			 } else {
				 readingsSingleUpdate($hash, "state", "password missing", 1);
			 }
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


sub Wattpilot_GetAuthHashMode($$) {
    my ($hash, $json) = @_;
    my $name = $hash->{NAME};

    my $attr_mode   = AttrVal($name, "authHash", "auto");
    my $device_mode = lc($json->{hash} // "");

    return $attr_mode if ($attr_mode ne "auto");

    return "bcrypt" if ($device_mode eq "bcrypt");
    return "pbkdf2";
}

sub Wattpilot_GetPassword {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $key  = "Wattpilot_" . $name . "_password";

    my ($err, $value) = getKeyValue($key);
    if (defined $err) {
        Log3 $name, 1, "Wattpilot ($name) - could not read password: $err";
        return undef;
    }

    return $value;
}

sub Wattpilot_GetPasswordHash {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $key  = "Wattpilot_" . $name . "_passwordhash";

    my ($err, $value) = getKeyValue($key);
    if (defined $err) {
        Log3 $name, 1, "Wattpilot ($name) - could not read password hash: $err";
        return undef;
    }

    return $value;
}

sub Wattpilot_SetStoredPasswordHash {
    my ($hash, $password_hash) = @_;
    my $name = $hash->{NAME};
    my $key  = "Wattpilot_" . $name . "_passwordhash";

    my $err = setKeyValue($key, $password_hash);
    if (defined $err) {
        Log3 $name, 1, "Wattpilot ($name) - failed to store password hash: $err";
        return 0;
    }

    return 1;
}

sub Wattpilot_DeleteStoredSecrets {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $err1 = setKeyValue("Wattpilot_" . $name . "_password", undef);
    Log3 $name, 1, "Wattpilot ($name) - failed to delete stored password: $err1"
      if defined $err1;

    my $err2 = setKeyValue("Wattpilot_" . $name . "_passwordhash", undef);
    Log3 $name, 1, "Wattpilot ($name) - failed to delete stored password hash: $err2"
      if defined $err2;
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
  <li>It supports reading status values, setting charging modes, starting/stopping charging, and supports both PBKDF2 and bcrypt based authentication.</li>
  <br>

  <a name="Wattpilot-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Wattpilot &lt;IP-Address&gt; [&lt;Serial&gt;]</code>
    <br><br>
    Defines a Wattpilot device.<br>
    <b>&lt;IP-Address&gt;</b>: The local IP address of the Wattpilot (for example 192.168.1.50).<br>
    <b>&lt;Serial&gt;</b>: (Optional) The serial number of the device. If not provided, it will be taken from the <code>hello</code> message during connection setup.<br>
    <br>
    The password is no longer part of the device definition and must be set separately via <code>set &lt;name&gt; Password &lt;secret&gt;</code>.
  </ul>
  <br>

  <a name="Wattpilot-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; Password &lt;secret&gt;</code><br>
        Stores the password persistently and starts a reconnect. The password is not stored in the device definition.</li>

    <li><code>set &lt;name&gt; Laden_starten &lt;Start|Stop&gt;</code><br>
        Manually starts or stops charging (corresponds to parameter <code>frc</code>).</li>

    <li><code>set &lt;name&gt; Strom &lt;6-32&gt;</code><br>
        Sets the charging current in ampere.</li>

    <li><code>set &lt;name&gt; Modus &lt;Default|Eco|NextTrip&gt;</code><br>
        Changes the charging mode:<br>
        <ul>
          <li><b>Default</b>: Standard charging</li>
          <li><b>Eco</b>: PV surplus charging</li>
          <li><b>NextTrip</b>: Scheduled charging for next trip</li>
        </ul>
    </li>

    <li><code>set &lt;name&gt; Zeit_NextTrip &lt;hh:mm&gt;</code><br>
        Sets the planned departure time for NextTrip mode. Internally this is converted to seconds after midnight.</li>
  </ul>
  <br>

  <a name="Wattpilot-get"></a>
  <b>Get</b>
  <ul>
    <li>Currently no dedicated <code>get</code> commands are implemented.</li>
  </ul>
  <br>

  <a name="Wattpilot-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval &lt;seconds&gt;</code><br>
        Interval in seconds for updating high-frequency readings such as voltages and phase currents. <code>0</code> means no rate limiting.</li>

    <li><code>update_while_idle &lt;0|1&gt;</code><br>
        If set to <code>1</code>, high-frequency values are also updated while not charging. Useful for diagnostics.</li>

    <li><code>defaultAmp &lt;value&gt;</code><br>
        Default value for the current setting slider in the frontend.</li>

    <li><code>disable &lt;0|1&gt;</code><br>
        Disables the module completely. If set to <code>1</code>, the connection is closed.</li>

    <li><code>authHash &lt;auto|pbkdf2|bcrypt&gt;</code><br>
        Selects the password hashing method for authentication.<br>
        <ul>
          <li><b>auto</b>: Use the method announced by the Wattpilot device</li>
          <li><b>pbkdf2</b>: Force legacy PBKDF2 authentication</li>
          <li><b>bcrypt</b>: Force bcrypt authentication (used by newer Wattpilot Flex devices)</li>
        </ul>
    </li>
  </ul>
  <br>

  <a name="Wattpilot-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code><br>
        Current connection/authentication state, e.g. <code>connecting</code>, <code>connected</code>, <code>password missing</code>, <code>auth_failed</code>.</li>

    <li><code>version</code><br>
        Firmware / protocol version reported by the Wattpilot.</li>

    <li><code>authHashMode</code><br>
        Effective authentication hash mode currently used (<code>pbkdf2</code> or <code>bcrypt</code>).</li>

    <li><code>CarState</code><br>
        Vehicle charging state, for example <code>Idle</code>, <code>Charging</code>, <code>Complete</code>.</li>

    <li><code>Laden_starten</code><br>
        Charging enable state derived from <code>frc</code>.</li>

    <li><code>Strom</code><br>
        Configured charging current in ampere.</li>

    <li><code>Modus</code><br>
        Current charging mode (<code>Default</code>, <code>Eco</code>, <code>NextTrip</code>).</li>

    <li><code>Zeit_NextTrip</code><br>
        Planned departure time in <code>hh:mm</code>.</li>

    <li><code>Energie_seit_Anstecken</code><br>
        Energy charged since the vehicle was plugged in.</li>

    <li><code>EnergyTotal</code><br>
        Total energy counter in kWh.</li>

    <li><code>power</code><br>
        Current total power.</li>

    <li><code>Voltage_L1</code>, <code>Voltage_L2</code>, <code>Voltage_L3</code><br>
        Voltage per phase.</li>

    <li><code>Current_L1</code>, <code>Current_L2</code>, <code>Current_L3</code><br>
        Current per phase.</li>

    <li><code>Power_L1</code>, <code>Power_L2</code>, <code>Power_L3</code><br>
        Power per phase.</li>
  </ul>
</ul>

=end html

=begin html_DE

<a name="Wattpilot"></a>
<h3>Wattpilot</h3>
<ul>
  <li>Dieses Modul dient zur Steuerung einer Fronius Wattpilot Wallbox über die WebSocket API V2.</li>
  <li>Es unterstützt das Auslesen von Statuswerten, das Setzen von Lademodi, das Starten/Stoppen der Ladung sowie die Authentifizierung per PBKDF2 und bcrypt.</li>
  <br>

  <a name="Wattpilot-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Wattpilot &lt;IP-Addresse&gt; [&lt;Seriennummer&gt;]</code>
    <br><br>
    Definiert ein Wattpilot-Device.<br>
    <b>&lt;IP-Addresse&gt;</b>: Die lokale IP-Adresse des Wattpiloten (z.B. 192.168.1.50).<br>
    <b>&lt;Seriennummer&gt;</b>: (Optional) Die Seriennummer des Geräts. Wenn sie nicht angegeben wird, wird sie beim Verbindungsaufbau aus der <code>hello</code>-Nachricht übernommen.<br>
    <br>
    Das Passwort ist nicht mehr Teil des <code>define</code>-Befehls und muss separat mit <code>set &lt;name&gt; Password &lt;secret&gt;</code> gesetzt werden.
  </ul>
  <br>

  <a name="Wattpilot-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; Password &lt;secret&gt;</code><br>
        Speichert das Passwort persistent und startet einen Reconnect. Das Passwort wird nicht in der Device-Definition gespeichert.</li>

    <li><code>set &lt;name&gt; Laden_starten &lt;Start|Stop&gt;</code><br>
        Startet oder stoppt die Ladung manuell (entspricht dem Parameter <code>frc</code>).</li>

    <li><code>set &lt;name&gt; Strom &lt;6-32&gt;</code><br>
        Setzt den Ladestrom in Ampere.</li>

    <li><code>set &lt;name&gt; Modus &lt;Default|Eco|NextTrip&gt;</code><br>
        Ändert den Lademodus:<br>
        <ul>
          <li><b>Default</b>: Standard-Laden</li>
          <li><b>Eco</b>: Laden mit PV-Überschuss</li>
          <li><b>NextTrip</b>: Geplantes Laden für die nächste Fahrt</li>
        </ul>
    </li>

    <li><code>set &lt;name&gt; Zeit_NextTrip &lt;hh:mm&gt;</code><br>
        Setzt die geplante Abfahrtszeit für den Modus NextTrip. Intern wird der Wert in Sekunden ab Mitternacht umgerechnet.</li>
  </ul>
  <br>

  <a name="Wattpilot-get"></a>
  <b>Get</b>
  <ul>
    <li>Derzeit sind keine eigenen <code>get</code>-Befehle implementiert.</li>
  </ul>
  <br>

  <a name="Wattpilot-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>interval &lt;sekunden&gt;</code><br>
        Intervall in Sekunden für die Aktualisierung hochfrequenter Messwerte wie Spannungen und Phasenströme. <code>0</code> bedeutet keine Begrenzung.</li>

    <li><code>update_while_idle &lt;0|1&gt;</code><br>
        Wenn auf <code>1</code> gesetzt, werden hochfrequente Messwerte auch im Leerlauf aktualisiert. Nützlich für Diagnosezwecke.</li>

    <li><code>defaultAmp &lt;wert&gt;</code><br>
        Standardwert für den Strom-Slider im Frontend.</li>

    <li><code>disable &lt;0|1&gt;</code><br>
        Deaktiviert das Modul vollständig. Bei <code>1</code> wird die Verbindung getrennt.</li>

    <li><code>authHash &lt;auto|pbkdf2|bcrypt&gt;</code><br>
        Wählt das Verfahren zur Passwort-Hash-Bildung für die Authentifizierung.<br>
        <ul>
          <li><b>auto</b>: Das vom Gerät angekündigte Verfahren wird verwendet</li>
          <li><b>pbkdf2</b>: Erzwingt das ältere PBKDF2-Verfahren</li>
          <li><b>bcrypt</b>: Erzwingt bcrypt (für neuere Wattpilot-Flex-Geräte)</li>
        </ul>
    </li>
  </ul>
  <br>

  <a name="Wattpilot-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code><br>
        Aktueller Verbindungs-/Authentifizierungsstatus, z.B. <code>connecting</code>, <code>connected</code>, <code>password missing</code> oder <code>auth_failed</code>.</li>

    <li><code>version</code><br>
        Vom Wattpilot gemeldete Firmware-/Protokollversion.</li>

    <li><code>authHashMode</code><br>
        Tatsächlich verwendetes Authentifizierungsverfahren (<code>pbkdf2</code> oder <code>bcrypt</code>).</li>

    <li><code>CarState</code><br>
        Fahrzeug-/Ladezustand, z.B. <code>Idle</code>, <code>Charging</code> oder <code>Complete</code>.</li>

    <li><code>Laden_starten</code><br>
        Ladefreigabe-Zustand aus <code>frc</code>.</li>

    <li><code>Strom</code><br>
        Eingestellter Ladestrom in Ampere.</li>

    <li><code>Modus</code><br>
        Aktueller Lademodus (<code>Default</code>, <code>Eco</code>, <code>NextTrip</code>).</li>

    <li><code>Zeit_NextTrip</code><br>
        Geplante Abfahrtszeit im Format <code>hh:mm</code>.</li>

    <li><code>Energie_seit_Anstecken</code><br>
        Geladene Energie in Wh seit dem Anstecken des Fahrzeugs.</li>

    <li><code>EnergyTotal</code><br>
        Gesamtenergiezähler in kWh.</li>

    <li><code>power</code><br>
        Aktuelle Gesamtleistung.</li>

    <li><code>Voltage_L1</code>, <code>Voltage_L2</code>, <code>Voltage_L3</code><br>
        Spannung pro Phase.</li>

    <li><code>Current_L1</code>, <code>Current_L2</code>, <code>Current_L3</code><br>
        Strom pro Phase.</li>

    <li><code>Power_L1</code>, <code>Power_L2</code>, <code>Power_L3</code><br>
        Leistung pro Phase.</li>
  </ul>
</ul>

=end html_DE

# Ende der Commandref
=cut
