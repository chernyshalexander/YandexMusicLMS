package Plugins::yandex::Ynison::ReconnectPolicy;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::ReconnectPolicy - decides how long to wait before the next connection attempt

=head1 DESCRIPTION

Mirrors the official Ynison client: a go-away is waited out exactly, a ladder
supplied by the server replaces the default one, and the ladder restarts when
the error kind changes or a session turns out healthy. Where the official
client stops until an external trigger, this policy waits idle_delay instead.
A pure object: no I/O and no LMS here.

=cut

# How long to wait before the next connection attempt. Mirrors the official
# client: a go-away is waited out exactly, a ladder supplied by the server
# replaces the default one, and the ladder restarts when the error kind
# changes or a session turns out healthy. Where the official client stops
# until an external trigger, this policy waits idle_delay instead. A pure
# object: no I/O and no LMS here.

use strict;
use warnings;

use Exporter ();
use Plugins::yandex::Ynison::Constants ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(parse_seconds parse_backoff_ladder);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

my $C = 'Plugins::yandex::Ynison::Constants';

sub parse_seconds {
    my ($v) = @_;
    return 0 unless defined $v && !ref $v && $v =~ /^\s*(\d+(?:\.\d+)?)\s*$/;
    return 0 + $1;
}

# "0:1000:5000:30000" -> (0, 1, 5, 30): seconds, sorted, without duplicates.
sub parse_backoff_ladder {
    my ($v) = @_;
    return () unless defined $v && !ref $v;
    my %seen = map { $_ => 1 } grep { /^\d+$/ } split /:/, $v;
    return map { $_ / 1000 } sort { $a <=> $b } keys %seen;
}

sub new {
    my ($class, %o) = @_;
    return bless {
        ladder    => [ @{ $o{ladder} || $C->RECONNECT_DELAYS() } ],
        idle      => $o{idle_delay} // $C->RECONNECT_IDLE_DELAY(),
        active    => [],       # the ladder in use
        index     => 0,        # position in the active ladder
        key       => '',       # kind of the last error
        go_away   => 0,
        retryable => 1,
    }, $class;
}

sub _adopt {
    my ($self, $key) = @_;
    return if $key eq $self->{key};
    $self->{key}   = $key;
    $self->{index} = 0;
    return;
}

# on_server_error($code, grpc_code => $i|undef, go_away => $seconds, ladder => $raw|undef)
sub on_server_error {
    my ($self, $code, %o) = @_;
    my $go = $o{go_away} || 0;
    $self->_adopt(($go ? 'go_away:' : 'basic:') . (defined $code ? $code : ''));
    my @new_ladder = parse_backoff_ladder($o{ladder});
    my $sig = join ',', @new_ladder;
    if ($sig ne join(',', @{ $self->{active} })) {
        $self->{active} = \@new_ladder;
        $self->{index}  = 0;                     # a genuinely new ladder restarts the position
    }
    $self->{go_away} = $go;
    my $retryable = 1;
    if (!$go && defined $o{grpc_code}) {
        $retryable = $C->RETRYABLE_GRPC_CODES()->{ $o{grpc_code} } ? 1 : 0;
    }
    $self->{retryable} = $retryable;
    return;
}

# A failure that carried no server directive (socket dropped, handshake failed).
sub on_transport_failure {
    my ($self) = @_;
    $self->_adopt('transport:');
    $self->{active}    = [];
    $self->{retryable} = 1;
    return;
}

# A frame of state arrived: the next failure starts afresh.
sub on_healthy {
    my ($self) = @_;
    $self->{active}    = [];
    $self->{index}     = 0;
    $self->{key}       = '';
    $self->{go_away}   = 0;
    $self->{retryable} = 1;
    return;
}

sub go_away_pending { $_[0]->{go_away} ? 1 : 0 }

sub next_delay {
    my ($self) = @_;
    if ($self->{go_away}) {
        my $delay = $self->{go_away};
        $self->{go_away} = 0;
        $self->{index}   = 0;
        return $delay;
    }
    return $self->{idle} unless $self->{retryable};
    my @ladder = @{ $self->{active} } ? @{ $self->{active} } : @{ $self->{ladder} };
    return $self->{idle} if $self->{index} >= @ladder;
    return $ladder[ $self->{index}++ ];
}

1;
