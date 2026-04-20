#!/usr/bin/perl
# Test: Basic Ynison connection and state updates
#
# Usage:
#   perl test/ynison_test_connection.pl <TOKEN> [DEVICE_ID]
#
# Where:
#   TOKEN - Yandex Music OAuth token
#   DEVICE_ID - Optional fixed device ID (if not set, random is generated)
#
# This test:
#   1. Creates Ynison instance
#   2. Connects to Yandex
#   3. Registers device
#   4. Logs all received state updates
#   5. Prints device info

use strict;
use warnings;
use JSON::XS::VersionOneAndTwo;
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/../lib";

# Mock LMS client for testing
package TestClient;
sub new {
    my ($class, $name) = @_;
    return bless { name => $name || 'Test LMS', id => 'test_player' }, $class;
}
sub name { $_[0]->{name} }
sub id { $_[0]->{id} }

package main;

my $token = shift @ARGV or die "Usage: $0 <TOKEN> [DEVICE_ID]\n";
my $device_id = shift @ARGV;

print "=== Ynison Test: Connection & State Updates ===\n\n";

# Create mock client
my $client = TestClient->new('Test LMS');

# Initialize Ynison (would be in Plugin.pm normally)
# NOTE: This loads the real Ynison_new.pm - make sure LMS dependencies are available
my $ynison = eval {
    require Plugins::yandex::Ynison;
    Plugins::yandex::Ynison->new($client, $token, 'test_user_123');
};

if ($@) {
    print "ERROR: Could not load Ynison module\n";
    print "Make sure LMS is properly set up in PERL5LIB\n";
    print "Error: $@\n";
    exit 1;
}

if (!$ynison) {
    print "ERROR: Failed to create Ynison instance\n";
    exit 1;
}

if ($device_id) {
    # Override with fixed device_id for testing
    $ynison->{device_id} = $device_id;
}

print "Device ID: " . $ynison->device_id() . "\n";
print "Status: " . ($ynison->enabled() ? "ENABLED" : "DISABLED") . "\n\n";

# Register state listener
my $state_count = 0;
$ynison->on_state(sub {
    my ($state) = @_;
    $state_count++;

    if ($state->{ping}) {
        print "[PING] Keep-alive\n";
        return;
    }

    print "\n--- State Update #$state_count ---\n";

    # Print active device
    if (my $active = $state->{active_device_id_optional}) {
        print "Active Device: $active\n";
    }

    # Print registered devices
    if (my $devices = $state->{devices}) {
        print "Devices in session: " . scalar(@$devices) . "\n";
        foreach my $dev (@$devices) {
            if (my $info = $dev->{info}) {
                print "  - " . $info->{title} . " (id: " . $info->{device_id} . ")\n";
            }
        }
    }

    # Print player state if available
    if (my $ps = $state->{player_state}) {
        if (my $queue = $ps->{player_queue}) {
            my $count = scalar(@{$queue->{playable_list} // []});
            my $idx = $queue->{current_playable_index} // -1;
            print "Queue: $count tracks, current index: $idx\n";

            if ($idx >= 0 && $queue->{playable_list}[$idx]) {
                my $track = $queue->{playable_list}[$idx];
                print "  Now playing: " . ($track->{title} // 'Unknown') . "\n";
            }
        }

        if (my $status = $ps->{status}) {
            my $paused = $status->{paused} ? 'PAUSED' : 'PLAYING';
            my $progress = $status->{progress_ms} // 0;
            my $duration = $status->{duration_ms} // 0;
            print "Status: $paused ($progress ms / $duration ms)\n";
        }
    }

    # Print if this is our echo
    if (my $queue = $state->{player_state}{player_queue}) {
        if (my $version = $queue->{version}) {
            if ($version->{device_id} eq $ynison->device_id) {
                print "[ECHO] This is our own update\n";
            }
        }
    }
});

print "Connecting to Yandex Ynison...\n";
$ynison->connect();

# Keep running for 30 seconds and print updates
print "Waiting for state updates (30s)...\n\n";

my $start = time();
while (time() - $start < 30) {
    sleep(0.1);
}

print "\n=== Test Complete ===\n";
print "Total updates received: $state_count\n";

$ynison->disconnect();
print "Disconnected.\n";

1;
