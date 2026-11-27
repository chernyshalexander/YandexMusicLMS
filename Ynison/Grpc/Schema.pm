package Plugins::yandex::Ynison::Grpc::Schema;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Grpc::Schema - the Ynison protobuf wire schema as plain data

=head1 DESCRIPTION

Message name -> ordered field table for the gRPC transport, consumed by
L<Plugins::yandex::Ynison::Grpc::Proto>. Pure data: no logic, no I/O, no LMS.
Every field number and enum value is transcribed verbatim from
docs/reference/ynison-proto/*.pyi (cross-checked against the compiled
descriptors the live probe used; a wrong field number is a Critical defect).

Each table entry is [field_name, field_number, wire_kind, ref] where wire_kind
is one of

    varint       int32/uint32 scalar, JSON number
    varint_i64   int64 scalar, digit-string in the JSON contract (see Message.pm i64)
    double       IEEE double (fixed 64-bit), JSON number
    bool         JSON \1 / \0
    string       utf8 text, ''
    bytes        raw octets, ''
    string_value google.protobuf.StringValue wrapper: plain string in JSON,
                 a one-field message (value = 1) on the wire
    message      nested message, ref names the table
    message_list repeated nested message, ref names the table
    packed_varint repeated scalars, packed on encode, both forms accepted on
                 decode; with a ref the values are enum names, else numbers
    string_list  repeated strings
    varint_enum  enum scalar: name string in JSON, varint on the wire,
                 ref names the enum table (enum_num/enum_name)

ref is undef for plain scalars. Entries are ordered by field number, so
encoding is deterministic. Fields whose referenced message table is absent
(Session, Queue, Shuffle, InitialEntity, PlayerQueueOptions, PlayerQueueInject,
UpdatePlayerQueueInject, UpdateVolume, SyncStateFromEOV - all out of the MVP
scope) are skipped on decode and rejected on encode: the codec dies naming the
missing table.

=cut

# The Ynison protobuf wire schema as plain data. Pure data: no logic, no I/O,
# no LMS. Field numbers and enum values are verbatim from
# docs/reference/ynison-proto/*.pyi, cross-checked against the compiled
# descriptors the live probe used.
#
#   varint        int32/uint32 scalar, JSON number
#   varint_i64    int64 scalar, digit-string in the JSON contract
#   double        IEEE double (fixed 64-bit), JSON number
#   bool          JSON \1 / \0
#   string        utf8 text, ''
#   bytes         raw octets, ''
#   string_value  google.protobuf.StringValue: plain string in JSON
#   message       nested message, ref names the table
#   message_list  repeated nested message, ref names the table
#   packed_varint repeated scalars, packed on encode, both forms on decode
#   string_list   repeated strings
#   varint_enum   enum: name string in JSON, varint on the wire
#
# Tables in the MVP scope only; fields pointing at out-of-scope tables are
# skipped on decode and die on encode.

use strict;
use warnings;

use Exporter ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(MESSAGES DEVICE_TYPE INTERCEPTION ENTITY_TYPE ENTITY_CONTEXT REPEAT_MODE
                    PLAYABLE_TYPE enum_num enum_name);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# ---- enums (name -> number; the reverse maps are built below) ---------------
my %DEVICE_TYPE = (
    UNSPECIFIED   => 0,
    WEB           => 1,
    ANDROID       => 2,
    IOS           => 3,
    SMART_SPEAKER => 4,
    WEB_TV        => 5,
    ANDROID_TV    => 6,
    APPLE_TV      => 7,
    ANDROID_WEAR  => 8,
    WEB_DESKTOP   => 9,
);
my %INTERCEPTION = (
    DO_NOT_INTERCEPT_BY_DEFAULT   => 0,
    INTERCEPT_IF_NO_ONE_ACTIVE    => 1,
    INTERCEPT_EAGER               => 2,
);
my %ENTITY_TYPE = (
    UNSPECIFIED => 0,
    ARTIST      => 1,
    PLAYLIST    => 2,
    ALBUM       => 3,
    RADIO       => 4,
    VARIOUS     => 5,
    GENERATIVE  => 6,
    FM_RADIO    => 7,
    VIDEO_WAVE  => 8,
    LOCAL_TRACKS => 9,
);
my %ENTITY_CONTEXT = (
    BASED_ON_ENTITY_BY_DEFAULT   => 0,
    USER_TRACKS                  => 1,
    DOWNLOADED_TRACKS            => 2,
    SEARCH                       => 3,
    MUSIC_HISTORY                => 4,
    MUSIC_HISTORY_SEARCH         => 5,
    ARTIST_MY_COLLECTION         => 6,
    ARTIST_FAMILIAR_FROM_WAVE    => 7,
);
my %REPEAT_MODE = (
    UNSPECIFIED => 0,
    NONE        => 1,
    ONE         => 2,
    ALL         => 3,
);
# Nested enum Playable.PlayableType.
my %PLAYABLE_TYPE = (
    UNSPECIFIED => 0,
    TRACK       => 1,
    LOCAL_TRACK => 2,
    INFINITE    => 3,
    VIDEO_CLIP  => 4,
);

# ---- message tables (ordered by field number) --------------------------------
my %MESSAGES = (
    YnisonDeviceInfoHeader => [
        ['type',        1, 'varint_enum', 'DEVICE_TYPE'],
        ['app_name',    2, 'string'],
        ['app_version', 3, 'string'],
    ],
    DeviceInfo => [
        ['device_id',   1, 'string'],
        ['title',       2, 'string'],
        ['type',        3, 'varint_enum', 'DEVICE_TYPE'],
        ['app_name',    4, 'string'],
        ['app_version', 5, 'string'],
    ],
    DeviceCapabilities => [
        ['can_be_player',            1, 'bool'],
        ['can_be_remote_controller', 2, 'bool'],
        ['volume_granularity',       3, 'varint'],    # uint32
    ],
    DeviceVolume => [
        ['volume',  1, 'double'],
        ['version', 2, 'message', 'UpdateVersion'],
    ],
    Device => [
        ['info',        1, 'message', 'DeviceInfo'],
        ['volume',      2, 'double'],
        ['capabilities', 3, 'message', 'DeviceCapabilities'],
        ['session',     4, 'message', 'Session'],          # no table: skipped on decode
        ['is_offline',  5, 'bool'],
        ['volume_info', 6, 'message', 'DeviceVolume'],
    ],
    UpdateVersion => [
        ['device_id',    1, 'string'],
        ['version',      2, 'varint_i64'],
        ['timestamp_ms', 3, 'varint_i64'],
    ],
    PlayingStatus => [
        ['progress_ms',    1, 'varint_i64'],
        ['duration_ms',    2, 'varint_i64'],
        ['paused',         3, 'bool'],
        ['playback_speed', 4, 'double'],
        ['version',        5, 'message', 'UpdateVersion'],
    ],
    Playable => [    # the fields the plugin consumes; video_clip_info=7,
                     # track_info=8, navigation_id=9, playback_action_id=10
                     # stay out of MVP scope
        ['playable_id',        1, 'string'],
        ['album_id_optional',  2, 'string_value'],
        ['playable_type',      3, 'varint_enum', 'PLAYABLE_TYPE'],
        ['from',               4, 'string'],
        ['title',              5, 'string'],
        ['cover_url_optional', 6, 'string_value'],
    ],
    TrackInfo => [
        ['track_source_key', 1, 'varint'],            # uint32
        ['batch_id_optional', 2, 'string_value'],
    ],
    PlayerQueue => [
        ['entity_id',            1,  'string'],
        ['entity_type',          2,  'varint_enum', 'ENTITY_TYPE'],
        ['current_playable_index', 3, 'varint'],      # int32, may be -1
        ['playable_list',        4,  'message_list', 'Playable'],
        ['options',              5,  'message', 'PlayerStateOptions'],
        ['version',              6,  'message', 'UpdateVersion'],
        ['shuffle_optional',     7,  'message', 'Shuffle'],          # no table: skipped
        ['entity_context',       8,  'varint_enum', 'ENTITY_CONTEXT'],
        ['from_optional',        9,  'string_value'],
        ['initial_entity_optional', 10, 'message', 'InitialEntity'],   # no table: skipped
        ['adding_options_optional', 11, 'message', 'PlayerQueueOptions'],# no table: skipped
        ['queue',                12, 'message', 'Queue'],             # WaveQueue oneof: skipped
        ['navigation_id_optional',      13, 'string_value'],
        ['filter_optional',             14, 'string_value'],
        ['playback_action_id_optional', 15, 'string_value'],
    ],
    PlayerStateOptions => [
        ['repeat_mode', 1, 'varint_enum', 'REPEAT_MODE'],
    ],
    PlayerState => [
        ['status',                     1, 'message', 'PlayingStatus'],
        ['player_queue',               2, 'message', 'PlayerQueue'],
        ['player_queue_inject_optional', 3, 'message', 'PlayerQueueInject'],  # no table: skipped
    ],
    UpdateFullState => [
        ['player_state',               1, 'message', 'PlayerState'],
        ['is_currently_active',        2, 'bool'],
        ['device',                     3, 'message', 'UpdateDevice'],
        ['sync_state_from_eov_optional', 4, 'message', 'SyncStateFromEOV'],  # no table: skipped
    ],
    UpdateActiveDevice => [
        ['device_id_optional', 1, 'string_value'],
    ],
    UpdatePlayingStatus => [
        ['playing_status', 1, 'message', 'PlayingStatus'],
    ],
    UpdatePlayerState => [
        ['player_state', 1, 'message', 'PlayerState'],
    ],
    UpdateSessionParams => [
        ['mute_events_if_passive', 1, 'bool'],
    ],
    UpdateVolumeInfo => [
        ['device_id',   1, 'string'],
        ['volume_info', 2, 'message', 'DeviceVolume'],
    ],
    RedirectRequest => [],
    RedirectResponse => [
        ['host',              1, 'string'],
        ['redirect_ticket',   2, 'string'],
        ['session_id',        3, 'varint_i64'],
        ['keep_alive_params', 4, 'message', 'KeepAliveParams'],
    ],
    KeepAliveParams => [
        ['keep_alive_time_seconds',    1, 'varint'],    # int32
        ['keep_alive_timeout_seconds', 2, 'varint'],    # int32
    ],
    PutYnisonStateRequest => [    # oneof branches flattened, numbers live-verified
        ['update_full_state',         1,  'message', 'UpdateFullState'],
        ['update_active_device',      2,  'message', 'UpdateActiveDevice'],
        ['update_playing_status',     3,  'message', 'UpdatePlayingStatus'],
        ['update_player_state',       4,  'message', 'UpdatePlayerState'],
        ['update_player_queue_inject', 6, 'message', 'UpdatePlayerQueueInject'],  # no table: skipped
        ['player_action_timestamp_ms', 7, 'varint_i64'],
        ['rid',                       8,  'string'],
        ['update_session_params',     9,  'message', 'UpdateSessionParams'],
        ['activity_interception_type', 10, 'varint_enum', 'INTERCEPTION'],
        ['update_volume_info',        11, 'message', 'UpdateVolumeInfo'],
        ['sync_state_from_eov',       12, 'message', 'SyncStateFromEOV'],    # no table: skipped
    ],
    PutYnisonStateResponse => [
        ['player_state',              1, 'message', 'PlayerState'],
        ['devices',                   2, 'message_list', 'Device'],
        ['active_device_id_optional', 3, 'string_value'],
        ['timestamp_ms',              4, 'varint_i64'],
        ['rid',                       5, 'string'],
    ],

    # Not in the plan's message list, but UpdateFullState.device is the core of
    # the registration message (Message.pm device_block feeds it), so the table
    # ships as part of the set.
    UpdateDevice => [
        ['info',         1, 'message', 'DeviceInfo'],
        ['volume',       2, 'double'],
        ['capabilities', 3, 'message', 'DeviceCapabilities'],
        ['volume_info',  4, 'message', 'DeviceVolume'],
    ],
);

my %ENUMS = (
    DEVICE_TYPE    => \%DEVICE_TYPE,
    INTERCEPTION   => \%INTERCEPTION,
    ENTITY_TYPE    => \%ENTITY_TYPE,
    ENTITY_CONTEXT => \%ENTITY_CONTEXT,
    REPEAT_MODE    => \%REPEAT_MODE,
    PLAYABLE_TYPE  => \%PLAYABLE_TYPE,
);

my %ENUM_NAMES = map { $_ => { reverse %{ $ENUMS{$_} } } } keys %ENUMS;

# Message name -> ordered field table ([name, number, kind, ref]).
sub MESSAGES { return \%MESSAGES }

sub DEVICE_TYPE   { \%DEVICE_TYPE }
sub INTERCEPTION  { \%INTERCEPTION }
sub ENTITY_TYPE   { \%ENTITY_TYPE }
sub ENTITY_CONTEXT{ \%ENTITY_CONTEXT }
sub REPEAT_MODE   { \%REPEAT_MODE }
sub PLAYABLE_TYPE { \%PLAYABLE_TYPE }

# enum_num('DEVICE_TYPE', 'WEB') -> 1; dies on an unknown name.
sub enum_num {
    my ($table, $name) = @_;
    my $map = $ENUMS{$table} or die "no $table enum table\n";
    return $map->{$name} if defined $name && exists $map->{$name};
    die "no $table value '$name'\n";
}

# enum_name('INTERCEPTION', 1) -> 'INTERCEPT_IF_NO_ONE_ACTIVE'; an unknown
# number comes back as the number itself (proto3-JSON behaviour).
sub enum_name {
    my ($table, $num) = @_;
    my $map = $ENUM_NAMES{$table} or die "no $table enum table\n";
    return $map->{$num} // $num;
}

1;
