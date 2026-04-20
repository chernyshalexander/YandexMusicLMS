#!/usr/bin/perl
# Example: How to handle incoming Yandex commands in LMS
#
# This shows the pattern for integrating Ynison_new.pm with the main plugin

use strict;
use warnings;

=head1 EXAMPLE: Handling Yandex Commands

When a state update arrives from Yandex, the listener receives a hash with:

  {
    "active_device_id_optional" => "device_id" or null,
    "devices" => [/* list of devices */],
    "player_state" => {
      "player_queue" => { /* queue info */ },
      "status" => { /* playback status */ }
    },
    "update_player_state" => { /* only if queue/status changed */ },
    "update_full_state" => { /* only on initial registration echo */ }
  }

=cut

# ===========================================================================
# Initialize Ynison with listener
# ===========================================================================

my $ynison = Plugins::yandex::Ynison->new($client, $token, $user_id);

# Register listener for incoming state updates
$ynison->on_state(sub {
    my ($state) = @_;
    _handle_yandex_state_update($client, $state);
});

# Start connection
$ynison->connect();


# ===========================================================================
# Handler: Process incoming state updates from Yandex
# ===========================================================================

sub _handle_yandex_state_update {
    my ($client, $state) = @_;

    # Extract relevant info
    my $active_device_id = $state->{active_device_id_optional};
    my $player_state = $state->{player_state};
    my $update = $state->{update_player_state} || $state->{update_full_state};

    # Skip if we're not the active device
    return unless $active_device_id eq $ynison->device_id;

    # Skip pings
    return if $state->{ping};

    return unless $update;

    my $queue = $update->{player_state}{player_queue};
    my $status = $update->{player_state}{status};

    # STEP 1: Rebuild queue if tracks changed
    if ($queue && $queue->{playable_list}) {
        _rebuild_playlist_from_yandex($client, $queue->{playable_list});
    }

    # STEP 2: Set playback position if index changed
    if (defined $queue->{current_playable_index}) {
        _skip_to_index($client, $queue->{current_playable_index});
    }

    # STEP 3: Apply playback status (pause/play)
    if (defined $status->{paused}) {
        if ($status->{paused}) {
            _pause_lms($client);
        } else {
            _play_lms($client);
        }
    }
}


# ===========================================================================
# Command Handlers: Apply changes in LMS
# ===========================================================================

sub _rebuild_playlist_from_yandex {
    my ($client, $playable_list) = @_;

    # $playable_list is array of:
    #   {
    #     "id" => "track_id",
    #     "title" => "Track Title",
    #     "duration_ms" => 180000,
    #     "cover_uri" => "avatars.yandex.net/..."
    #   }

    # Map Yandex tracks to LMS tracks
    # 1. For each Yandex track, look up in Yandex API or cache
    # 2. Get LMS playlistIndex
    # 3. Rebuild LMS playlist

    return unless @$playable_list;

    my @lms_playlist = map {
        {
            url   => _get_track_url($_->{id}),
            title => $_->{title},
        }
    } @$playable_list;

    # Clear existing playlist
    $client->execute(['playlist', 'clear']);

    # Add all tracks
    foreach my $track (@lms_playlist) {
        $client->execute(['playlist', 'add', $track->{url}]);
    }

    # Optionally update metadata
    foreach my $i (0 .. $#@$playable_list) {
        # Store metadata for display
    }
}

sub _skip_to_index {
    my ($client, $index) = @_;

    # Set current track to specified index
    # In LMS: playlist index is 0-based
    $client->execute(['playlist', 'index', $index]);
}

sub _play_lms {
    my ($client) = @_;
    $client->execute(['play']);
}

sub _pause_lms {
    my ($client) = @_;
    $client->execute(['pause']);
}

sub _get_track_url {
    my ($track_id) = @_;
    # Implement: Get streaming URL for Yandex track
    # Use Yandex API or cache
    return "http://localhost:9000/musicsearch/$track_id/download";
}


# ===========================================================================
# User Sends Commands Back to Yandex
# ===========================================================================

# When user controls playback locally (via LMS or remote), send it back to Yandex

sub _user_pressed_pause {
    my ($client) = @_;

    # Get current state from Yandex
    my $state = $ynison->latest_state();
    return unless $state;

    # Build pause command
    my $cmd = Plugins::yandex::Ynison::build_pause_request(
        $ynison->device_id,
        $state->{player_state}{status},
        1  # paused=true
    );

    # Send back to Yandex
    $ynison->send_command($cmd);
}

sub _user_pressed_play {
    my ($client) = @_;

    my $state = $ynison->latest_state();
    return unless $state;

    my $cmd = Plugins::yandex::Ynison::build_pause_request(
        $ynison->device_id,
        $state->{player_state}{status},
        0  # paused=false
    );

    $ynison->send_command($cmd);
}

sub _user_pressed_next {
    my ($client) = @_;

    my $state = $ynison->latest_state();
    return unless $state;

    my $cmd = Plugins::yandex::Ynison::build_next_track_request(
        $ynison->device_id,
        $state->{player_state}
    );

    $ynison->send_command($cmd);
}

sub _user_pressed_prev {
    my ($client) = @_;

    my $state = $ynison->latest_state();
    return unless $state;

    my $cmd = Plugins::yandex::Ynison::build_prev_track_request(
        $ynison->device_id,
        $state->{player_state}
    );

    $ynison->send_command($cmd);
}


# ===========================================================================
# Integration Points with Plugin.pm
# ===========================================================================

=head2 Where to add this in Plugin.pm

  1. On plugin init (playerStatusChange or trackChanged):
     - Create Ynison instance and register listener

  2. When user plays/pauses:
     - Call $ynison->send_command() with updated status

  3. When user skips track:
     - Call $ynison->send_command() with new index

  4. On plugin shutdown:
     - Call $ynison->disconnect()

=cut

1;
