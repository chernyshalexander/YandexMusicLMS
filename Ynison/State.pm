package Plugins::yandex::Ynison::State;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::State - the server-known state and the meaning of every inbound Ynison frame

=head1 DESCRIPTION

Holds the retained player_state, the device list and the active device, and
decides what each inbound frame means: our echo, a stale relay, a peer
command. Keeps the dedup baseline the sender consults before publishing a
status, and extrapolates the playback position from it. Pure object: time is
read through the injected now_s, no I/O and no LMS here.

=cut

# The server-known state: player_state, devices, the active device. Decides
# what each inbound frame means (our echo, a stale relay, a peer command) and
# keeps the dedup baseline the sender consults before publishing a status.
# A pure object: time is read through now_s, no I/O and no LMS here.

use strict;
use warnings;

use Time::HiRes ();

use Plugins::yandex::Ynison::Constants ();
use Plugins::yandex::Ynison::Message ();

my $C = 'Plugins::yandex::Ynison::Constants';

# \1 / \0 (JSON booleans) and plain values alike.
sub _truth { my $v = shift; return (ref $v ? $$v : $v) ? 1 : 0 }

sub new {
    my ($class, %o) = @_;
    return bless {
        device_id  => $o{device_id},
        now_s      => $o{now_s} // sub { Time::HiRes::time() },
        ps         => {},
        devices    => [],
        active     => undef,
        baseline   => undef,     # {progress_ms, duration_ms, paused, anchor, version}
        watermarks => [],        # the recent sends, newest last
    }, $class;
}

sub player_state     { $_[0]->{ps} }
sub status           { $_[0]->{ps}{status} }
sub player_queue     { $_[0]->{ps}{player_queue} }
sub devices          { $_[0]->{devices} }
sub active_device_id { $_[0]->{active} }

sub is_active { my ($s) = @_; return defined $s->{active} && $s->{active} eq $s->{device_id} ? 1 : 0 }

sub current_index {
    my ($s) = @_;
    my $q = $s->{ps}{player_queue} or return -1;
    my $i = $q->{current_playable_index};
    return defined $i && $i =~ /^\d+$/ ? 0 + $i : -1;
}

sub current_track_id {
    my ($s) = @_;
    my $q = $s->{ps}{player_queue} or return undef;
    my $list = $q->{playable_list} or return undef;
    my $i = $s->current_index;
    return undef if $i < 0 || $i > $#$list;
    return $list->[$i]{playable_id};
}

sub is_paused {
    my ($s) = @_;
    my $st = $s->{ps}{status} or return 1;
    return _truth($st->{paused}) ? 1 : 0;
}

# The position the last known status implies right now.
sub progress_ms {
    my ($s) = @_;
    my $b = $s->{baseline} or return 0;
    my $p = $b->{paused} ? $b->{progress_ms} : $b->{progress_ms} + int(($s->{now_s}->() - $b->{anchor}) * 1000);
    return Plugins::yandex::Ynison::Message::clamp_progress($p, $b->{duration_ms});
}

sub own_volume {
    my ($s) = @_;
    for my $d (@{ $s->{devices} }) {
        next unless ($d->{info}{device_id} // '') eq $s->{device_id};
        my $v = $d->{volume_info}{volume};
        return defined $v && $v =~ /^[\d.]+$/ ? 0 + $v : undef;
    }
    return undef;
}

# note_status_sent($progress_ms, $duration_ms, $paused): the sender reports a
# successful update_playing_status; it anchors the dedup baseline and leaves a
# watermark for the zero-version echo.
sub note_status_sent {
    my ($s, $progress, $duration, $paused) = @_;
    $s->_set_baseline($progress, $duration, $paused ? 1 : 0, undef);
    my $track = $s->current_track_id // '';
    push @{ $s->{watermarks} }, {
        track    => $track,
        progress => 0 + $progress,
        duration => 0 + $duration,
        paused   => $paused ? 1 : 0,
        at       => $s->{now_s}->(),
    };
    shift @{ $s->{watermarks} } while @{ $s->{watermarks} } > $C->ECHO_WATERMARKS_MAX();
    return;
}

# status_matches($progress, $duration, $paused): a best-effort status within
# the dedup window of the extrapolated baseline does not need to be sent.
sub status_matches {
    my ($s, $progress, $duration, $paused) = @_;
    my $b = $s->{baseline} or return 0;
    return 0 if $b->{paused} != ($paused ? 1 : 0) || $b->{duration_ms} != (0 + ($duration // 0));
    my $p = $b->{paused} ? $b->{progress_ms} : $b->{progress_ms} + int(($s->{now_s}->() - $b->{anchor}) * 1000);
    return abs($p - (0 + ($progress // 0))) <= $C->STATUS_DEDUP_WINDOW_MS() ? 1 : 0;
}

sub _set_baseline {
    my ($s, $progress, $duration, $paused, $version) = @_;
    $s->{baseline} = {
        progress_ms => 0 + ($progress // 0),
        duration_ms => 0 + ($duration // 0),
        paused      => $paused ? 1 : 0,
        anchor      => $s->{now_s}->(),
        version     => $version,
    };
    return;
}

# A status authored by another device under a new version is a fresh command
# even when it lands on the position we already know; a repeat of the newest
# known one is a relay.
sub _is_known_status {
    my ($s, $st) = @_;
    return 0 unless $s->{baseline} && ref $st eq 'HASH';
    my $v = $st->{version} || {};
    my $author = $v->{device_id} // '';
    return 0 if $author && $author ne $s->{device_id}
        && (!defined $s->{baseline}{version} || !$s->_version_eq($v, $s->{baseline}{version}));
    my $same = ($st->{progress_ms} // '') eq "$s->{baseline}{progress_ms}"
            && ($st->{duration_ms} // '') eq "$s->{baseline}{duration_ms}"
            && _truth($st->{paused}) == $s->{baseline}{paused};
    return $same ? 1 : 0;
}

sub _version_eq {
    my (undef, $a, $b) = @_;
    return (($a->{device_id} // '') eq ($b->{device_id} // '')
        && ($a->{version} // '') eq ($b->{version} // '')
        && ($a->{timestamp_ms} // '') eq ($b->{timestamp_ms} // '')) ? 1 : 0;
}

# _classify($ps): dual authorship, or the zero-version twin of a recent send.
sub _classify {
    my ($s, $ps) = @_;
    my $q_author = ((($ps->{player_queue} || {})->{version} || {})->{device_id} // '');
    my $s_author = ((($ps->{status}       || {})->{version} || {})->{device_id} // '');
    return (1, 0) if $q_author eq $s->{device_id} && $s_author eq $s->{device_id};

    my $st = $ps->{status};
    return (0, 0) unless ref $st eq 'HASH';
    my $v = $st->{version} || {};
    return (0, 0) unless ($v->{device_id} // '') eq '' && ($v->{version} // '') eq '0' && ($v->{timestamp_ms} // '') eq '0';
    return (0, 0) unless ("$st->{progress_ms}" =~ /^-?\d+$/) && ("$st->{duration_ms}" =~ /^-?\d+$/);
    my ($progress, $duration) = (0 + $st->{progress_ms}, 0 + $st->{duration_ms});
    my $paused = _truth($st->{paused}) ? 1 : 0;
    my $track = $s->current_track_id // '';
    my $now = $s->{now_s}->();
    for my $w (reverse @{ $s->{watermarks} }) {
        next if $now - $w->{at} > $C->ECHO_WATERMARK_WINDOW_S();
        next unless $track eq $w->{track};
        return (1, 1) if abs($progress - $w->{progress}) <= 1
            && $duration == $w->{duration} && $paused == $w->{paused};
    }
    return (0, 0);
}

# apply_frame($frame) -> {is_echo, suppress_status, status_is_relay,
#                         item_changed, active_changed, devices_changed}
sub apply_frame {
    my ($s, $frame) = @_;
    return {} unless ref $frame eq 'HASH';

    my $incoming = $frame->{player_state};
    my ($is_echo, $suppress) = (0, 0);
    my $relay = !(ref $incoming eq 'HASH' && exists $incoming->{status});
    if (ref $incoming eq 'HASH') {
        Plugins::yandex::Ynison::Message::normalize_player_state($incoming);
        ($is_echo, $suppress) = $s->_classify($incoming);
        if (exists $incoming->{status}) {
            # The verdict reads the baseline as it was BEFORE this frame: a
            # repeat of the newest known status is a relay, and a relay keeps
            # the anchor its position is extrapolated from.
            $relay = 1 if $s->_is_known_status($incoming->{status});
            if (!$suppress && !$relay) {
                my $st = $incoming->{status};
                $s->_set_baseline($st->{progress_ms}, $st->{duration_ms},
                    _truth($st->{paused}), $st->{version});
            }
        }
    }

    my ($old_track, $old_index, $old_active) = ($s->current_track_id, $s->current_index, $s->{active});

    # Top-level keys replace wholesale; absent keys keep the retained blocks.
    # A suppressed echo leaves the retained status untouched.
    if (ref $incoming eq 'HASH') {
        my %merge = %$incoming;
        delete $merge{status} if $suppress;
        $s->{ps} = { %{ $s->{ps} }, %merge };
    }
    $s->{devices} = $frame->{devices} if exists $frame->{devices};

    my $s_author = ref $incoming eq 'HASH' && ref $incoming->{status} eq 'HASH'
        ? ($incoming->{status}{version}{device_id} // '') : '';
    if (!exists $frame->{active_device_id_optional} && $s_author eq $C->SERVER_DISCONNECT_AUTHOR()) {
        $s->{active} = undef;
    }
    elsif (exists $frame->{active_device_id_optional}) {
        $s->{active} = defined $frame->{active_device_id_optional} ? "$frame->{active_device_id_optional}" : undef;
    }

    my $new_track = $s->current_track_id;
    my $new_index = $s->current_index;
    my $kept      = $is_echo && ($new_track // '') eq ($old_track // '') && $new_index == $old_index ? 1 : 0;
    my $changed   = ($new_track // '') ne ($old_track // '') || $new_index != $old_index ? 1 : 0;
    my $active_changed = (defined $old_active) ne (defined $s->{active})
        || (defined $old_active && defined $s->{active} && $old_active ne $s->{active}) ? 1 : 0;

    return {
        is_echo         => $is_echo,
        suppress_status => $suppress,
        status_is_relay => $relay ? 1 : 0,
        item_changed    => ($changed && !$kept) ? 1 : 0,
        active_changed  => $active_changed,
        devices_changed => exists $frame->{devices} ? 1 : 0,
    };
}

1;
