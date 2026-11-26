package Plugins::yandex::Ynison::Constants;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Constants - protocol constants and policy defaults of the Ynison client

=head1 DESCRIPTION

Single place of record for every endpoint, timeout, frame limit and error code
the Ynison engine uses. Pure data: nothing here loads Slim::* or touches the
network.

=cut

# Protocol constants and policy defaults of the Ynison client. Pure data:
# nothing here loads Slim::* or touches the network.

use strict;
use warnings;

use constant {
    YNISON_REDIRECT_HOST => 'ynison.music.yandex.ru',
    YNISON_REDIRECT_PATH => '/redirector.YnisonRedirectService/GetRedirectToYnison',
    YNISON_STATE_PATH    => '/ynison_state.YnisonStateService/PutYnisonState',
    YNISON_ORIGIN        => 'https://music.yandex.ru',
    YNISON_PORT          => 443,

    # the gRPC transport (pref ynison_transport=grpc); the WS path ignores these.
    # Endpoints live-verified (2026-11-26): the redirector answers on the .net host.
    GRPC_REDIRECT_HOST   => 'ynison.music.yandex.net',
    GRPC_REDIRECT_METHOD => '/ynison_redirect.YnisonRedirectService/GetRedirectToYnison',
    GRPC_STATE_METHOD    => '/ynison_state.YnisonStateService/PutYnisonState',
    GRPC_ALPN            => 'h2',

    DEVICE_TYPE_WEB     => 'WEB',    # DeviceType.WEB as protobuf-JSON (enum names)
    DEVICE_TYPE_WEB_NUM => 1,        # DeviceType.WEB in the Sec-WebSocket-Protocol header (numbers)
    APP_NAME            => 'yandex-music-lms',
    APP_VERSION         => '0.797',  # keep equal to <version> in install.xml
    VOLUME_GRANULARITY  => 100,

    INTERCEPT_NONE    => 'DO_NOT_INTERCEPT_BY_DEFAULT',
    INTERCEPT_IF_FREE => 'INTERCEPT_IF_NO_ONE_ACTIVE',
    INTERCEPT_EAGER   => 'INTERCEPT_EAGER',

    RECONNECT_DELAYS      => [1, 5, 30],
    RECONNECT_IDLE_DELAY  => 300,
    RETRYABLE_GRPC_CODES  => { 8 => 1, 10 => 1, 14 => 1 },
    RECONNECT_ERROR_CODES => { '300100001' => 1, '300100002' => 1 },

    STRICT_SEND_WAIT        => 5,
    STATUS_DEDUP_WINDOW_MS  => 2000,
    ECHO_WATERMARK_WINDOW_S => 2,
    ECHO_WATERMARKS_MAX     => 8,

    WS_CONNECT_TIMEOUT      => 15,
    REDIRECT_TIMEOUT        => 10,
    FIRST_FRAME_TIMEOUT     => 10,
    WS_HEARTBEAT_DEFAULT    => 20,
    WS_PING_TIMEOUT_DEFAULT => 20,
    WS_MIN_HEARTBEAT        => 5,
    MAX_FRAME_SIZE_IN       => 64 * 1024 * 1024,
    MAX_FRAME_SIZE_OUT      => 16 * 1024 * 1024,
    MAX_WRITE_QUEUE         => 100,

    SETTLE_WINDOW   => 2.0,
    RECLAIM_DELAY   => 0.3,
    CONV_QUIET_S        => 600,  # no frames and no online peers this long: the session looks lonely
    CONV_PROBE_EVERY_S  => 600,  # at most one convergence probe per this interval
    STATUS_TICK     => 5,
    VOLUME_DEBOUNCE => 0.2,
    QUEUE_WINDOW    => 200,

    ERR_PROGRESS_RANGE      => '400030001',
    ERR_QUEUE_BOUNDARY      => '400030002',
    ERR_DEVICE_DISPLACED    => '400090001',
    ERR_REBALANCED          => '300100001',
    ERR_NOT_SERVED          => '300100002',
    ERR_UNAUTHENTICATED     => '400160000',
    ERR_TOO_MANY_RECONNECTS => '500140000',

    SERVER_DISCONNECT_AUTHOR => 'server-paused-on-active-device-disconnecting',
};

1;
