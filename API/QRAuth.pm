package Plugins::yandex::API::QRAuth;

=encoding utf8

=head1 NAME

Plugins::yandex::API::QRAuth - Native Yandex Passport QR code login flow

=head1 DESCRIPTION

Implements native Yandex Passport QR flow (matching ya-passport-auth / Music Assistant reference implementation):
1. GET https://passport.yandex.ru/pwl-yandex with mobile user agent -> extract CSRF token.
2. POST https://passport.yandex.ru/pwl-yandex/api/passport/auth/password/submit -> auth state with track_id.
3. POST https://passport.yandex.ru/pwl-yandex/api/passport/auth/magic/code -> magic QR URL.
4. Polling POST https://passport.yandex.ru/pwl-yandex/api/passport/auth/magic/code/status -> status pending or otp_auth_finished.
5. POST https://passport.yandex.ru/pwl-yandex/api/passport/sessions/get_session -> deposits session cookies into cookie jar.
6. POST https://mobileproxy.passport.yandex.net/1/bundle/oauth/token_by_sessionid -> x_token.
7. POST https://oauth.mobile.yandex.net/1/token -> music-scoped OAuth token.

=cut

use strict;
use warnings;
use utf8;

use HTTP::Cookies;
use LWP::UserAgent;
use HTTP::Request;
use URI::Escape qw(uri_escape_utf8);
use Scalar::Util qw(blessed);

BEGIN {
    eval {
        require JSON::XS::VersionOneAndTwo;
        JSON::XS::VersionOneAndTwo->import;
        1;
    } || eval {
        require JSON::PP;
        JSON::PP->import(qw(encode_json decode_json to_json from_json));
        1;
    };
    if (!defined &decode_json) {
        require JSON::PP;
        *decode_json = \&JSON::PP::decode_json;
    }
    if (!defined &encode_json) {
        require JSON::PP;
        *encode_json = \&JSON::PP::encode_json;
    }
}

use constant MOBILE_UA => 'com.yandex.mobile.auth.sdk/7.42.0 (Xiaomi Redmi; Android 10) Yandex';

use constant PASSPORT_CLIENT_ID     => 'c0ebe342af7d48fbbbfcf2d2eedb8f9e';
use constant PASSPORT_CLIENT_SECRET => 'ad0a908f0aa341a182a37ecd75bc319e';

use constant MUSIC_CLIENT_ID        => '23cabbbdc6cd418abb4b39c32c41195d';
use constant MUSIC_CLIENT_SECRET    => '53bc75238f0c4d08a118e51fe9203300';

use constant PASSPORT_URL            => 'https://passport.yandex.ru';
use constant PWL_URL                 => 'https://passport.yandex.ru/pwl-yandex';
use constant BFF_URL                 => 'https://passport.yandex.ru/pwl-yandex/api/passport';
use constant PASSPORT_API_URL        => 'https://mobileproxy.passport.yandex.net';
use constant TOKEN_BY_SESSIONID_URL  => 'https://mobileproxy.passport.yandex.net/1/bundle/oauth/token_by_sessionid';
use constant MUSIC_TOKEN_URL         => 'https://oauth.mobile.yandex.net/1/token';

# Session storage for in-progress QR flows
our %ACTIVE_SESSIONS;

# Parse JSON safely
sub _parse_json_response {
    my ($content) = @_;
    return undef unless defined $content && length($content);
    my $json;
    if (defined &decode_json) {
        $json = eval { decode_json($content) };
    }
    if (!$json && eval { require JSON::PP; 1 }) {
        $json = eval { JSON::PP::decode_json($content) };
    }
    return $json;
}

# Format error diagnostics from API response
sub _format_error_message {
    my ($json, $res, $default_msg) = @_;
    if ($json && ref $json eq 'HASH') {
        if ($json->{errors} && ref $json->{errors} eq 'ARRAY' && @{$json->{errors}}) {
            return join(', ', @{$json->{errors}});
        }
        if ($json->{error_description}) {
            return $json->{error_description};
        }
        if ($json->{error}) {
            return $json->{error};
        }
        if ($json->{message}) {
            return $json->{message};
        }
    }
    if ($res && blessed($res) && $res->can('status_line')) {
        return $res->status_line;
    }
    return $default_msg || 'Unknown error';
}

# Extract CSRF token from HTML
sub _extract_csrf {
    my ($html) = @_;
    return '' unless defined $html;

    if ($html =~ /"csrf_token"\s*value="([^"]+)"/) {
        return $1;
    }
    if ($html =~ /'csrf_token'\s*:\s*'([^']+)'/) {
        return $1;
    }
    if ($html =~ /"csrf_token"\s*:\s*"([^"]+)"/) {
        return $1;
    }
    if ($html =~ /(?:window\.)?__CSRF__\s*=\s*"([^"]+)"/) {
        return $1;
    }
    return '';
}

# Format cookie header for Ya-Client-Cookie from HTTP::Cookies jar
sub _extract_cookie_header {
    my ($jar) = @_;
    return '' unless $jar;

    # Prefer standard RFC cookie filter via dummy request to passport domain
    my $dummy_req = HTTP::Request->new(GET => PASSPORT_URL . '/');
    $jar->add_cookie_header($dummy_req);
    my $header = $dummy_req->header('Cookie');
    if ($header && length($header)) {
        $header =~ s/[\r\n]//g;
        return $header;
    }

    # Fallback scan across all jar entries
    my %cookies;
    $jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $rest) = @_;
        if ($domain =~ /(?:^|\.)passport\.yandex\.ru$/ || $domain =~ /(?:^|\.)yandex\.ru$/) {
            $val =~ s/[\r\n]//g;
            $cookies{$key} = $val;
        }
    });

    return join('; ', map { "$_=$cookies{$_}" } sort keys %cookies);
}

# Build UserAgent configured for QR flow
sub _get_ua {
    my ($jar) = @_;
    my $ua = LWP::UserAgent->new(
        timeout  => 15,
        ssl_opts => { verify_hostname => 1 },
    );
    $ua->agent(MOBILE_UA);
    $ua->cookie_jar($jar) if $jar;
    return $ua;
}

# Encode form data helper
sub _encode_form_data {
    my ($data) = @_;
    my @parts;
    foreach my $k (sort keys %$data) {
        my $v = $data->{$k};
        next unless defined $v;
        push @parts, uri_escape_utf8($k) . '=' . uri_escape_utf8($v);
    }
    return join('&', @parts);
}

# -------------------------------------------------------------------------
# Synchronous Core Flow Steps
# -------------------------------------------------------------------------

sub start_qr_login_sync {
    my ($class, %args) = @_;

    # Prune stale sessions older than 1 hour
    my $now = time();
    for my $t (keys %ACTIVE_SESSIONS) {
        if ($now - ($ACTIVE_SESSIONS{$t}->{created_at} || 0) > 3600) {
            delete $ACTIVE_SESSIONS{$t};
        }
    }

    my $jar = HTTP::Cookies->new;
    my $ua = _get_ua($jar);

    # Step 1: GET /pwl-yandex
    my $pwl_res = $ua->get(PWL_URL);
    unless ($pwl_res->is_success) {
        die "Failed to fetch Passport PWL page: " . $pwl_res->status_line . "\n";
    }

    my $csrf = _extract_csrf($pwl_res->content);
    unless ($csrf) {
        die "CSRF token not found in Passport HTML\n";
    }

    my %bff_headers = (
        'X-CSRF-Token' => $csrf,
        'Origin'       => PASSPORT_URL,
        'Referer'      => PWL_URL,
    );

    # Step 2: POST /api/passport/auth/password/submit
    my $submit_req = HTTP::Request->new(POST => BFF_URL . '/auth/password/submit');
    $submit_req->header(%bff_headers);
    $submit_req->header('Content-Type' => 'application/json');
    $submit_req->content(encode_json({ retpath => PASSPORT_URL . '/profile' }));

    my $submit_res = $ua->request($submit_req);
    my $auth_state = _parse_json_response($submit_res->content);
    unless ($submit_res->is_success && $auth_state && $auth_state->{track_id}) {
        my $err = _format_error_message($auth_state, $submit_res, 'Passport submit failed');
        die "Passport submit failed: $err\n";
    }

    my $track_id = $auth_state->{track_id};

    # Step 3: POST /api/passport/auth/magic/code
    my $magic_req = HTTP::Request->new(POST => BFF_URL . '/auth/magic/code');
    $magic_req->header(%bff_headers);
    $magic_req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $magic_req->content(_encode_form_data({
        location_id    => '0',
        magic_track_id => $track_id,
        track_id       => '',
    }));

    my $magic_res = $ua->request($magic_req);
    my $magic_json = _parse_json_response($magic_res->content);
    unless ($magic_res->is_success && $magic_json && $magic_json->{link}) {
        my $err = _format_error_message($magic_json, $magic_res, 'Magic code request failed');
        die "Magic code request failed: $err\n";
    }

    my $qr_url = $magic_json->{link};

    # Store session handle
    $ACTIVE_SESSIONS{$track_id} = {
        track_id   => $track_id,
        csrf_token => $csrf,
        auth_state => $auth_state,
        qr_url     => $qr_url,
        jar        => $jar,
        created_at => time(),
        expires_in => $args{expires_in} || 300,
    };

    return {
        track_id   => $track_id,
        qr_url     => $qr_url,
        expires_in => $args{expires_in} || 300,
        interval   => $args{interval} || 3,
    };
}

sub poll_qr_token_sync {
    my ($class, $track_id, %args) = @_;

    unless ($track_id && exists $ACTIVE_SESSIONS{$track_id}) {
        return {
            status  => 'error',
            error   => 'invalid_track_id',
            message => 'QR session expired or not found',
        };
    }

    my $session = $ACTIVE_SESSIONS{$track_id};
    my $jar     = $session->{jar};
    my $csrf    = $session->{csrf_token};
    my $ua      = _get_ua($jar);

    # Step 4: Polling /api/passport/auth/magic/code/status
    my $status_req = HTTP::Request->new(POST => BFF_URL . '/auth/magic/code/status');
    $status_req->header(
        'X-CSRF-Token' => $csrf,
        'Origin'       => PASSPORT_URL,
        'Referer'      => PWL_URL,
        'Content-Type' => 'application/json',
    );
    my %status_body = (
        %{$session->{auth_state} || {}},
        retpath  => PASSPORT_URL . '/profile',
        track_id => $track_id,
    );
    $status_req->content(encode_json(\%status_body));

    my $status_res = $ua->request($status_req);
    my $status_json = _parse_json_response($status_res->content);

    unless ($status_res->is_success && $status_json) {
        return {
            status  => 'error',
            error   => 'network_error',
            message => 'Failed to poll QR status: ' . $status_res->status_line,
        };
    }

    # If server explicitly returned an error (e.g. invalid CSRF, rejected flow)
    if (($status_json->{status} && $status_json->{status} eq 'error') || $status_json->{error} || $status_json->{errors}) {
        delete $ACTIVE_SESSIONS{$track_id};
        my $err_msg = _format_error_message($status_json, $status_res, 'QR authorization error');
        return {
            status  => 'error',
            error   => $status_json->{error} || 'auth_error',
            message => $err_msg,
        };
    }

    my $state = $status_json->{state};
    if (!$state || $state ne 'otp_auth_finished') {
        # Check if flow session expired
        if (time() - $session->{created_at} > $session->{expires_in}) {
            delete $ACTIVE_SESSIONS{$track_id};
            return {
                status  => 'error',
                error   => 'expired_token',
                message => 'QR code expired',
            };
        }
        return { status => 'pending' };
    }

    # Step 5: otp_auth_finished! Get session cookies
    my $session_track_id = $status_json->{trackId} || $status_json->{track_id};
    unless ($session_track_id) {
        delete $ACTIVE_SESSIONS{$track_id};
        return {
            status  => 'error',
            error   => 'missing_track_id',
            message => 'QR status confirmed but missing trackId',
        };
    }

    my $sess_req = HTTP::Request->new(POST => BFF_URL . '/sessions/get_session');
    $sess_req->header(
        'X-CSRF-Token' => $csrf,
        'Origin'       => PASSPORT_URL,
        'Referer'      => PWL_URL,
        'Content-Type' => 'application/x-www-form-urlencoded',
    );
    $sess_req->content(_encode_form_data({ track_id => $session_track_id }));

    my $sess_res = $ua->request($sess_req);
    unless ($sess_res->is_success) {
        delete $ACTIVE_SESSIONS{$track_id};
        return {
            status  => 'error',
            error   => 'session_failed',
            message => 'Failed to deposit session cookies: ' . $sess_res->status_line,
        };
    }

    # Step 6: Exchange cookies for x_token
    my $cookie_header = _extract_cookie_header($jar);
    unless ($cookie_header) {
        delete $ACTIVE_SESSIONS{$track_id};
        return {
            status  => 'error',
            error   => 'no_cookies',
            message => 'No session cookies found after QR confirmation',
        };
    }

    my $xtoken_req = HTTP::Request->new(POST => TOKEN_BY_SESSIONID_URL);
    $xtoken_req->header(
        'Ya-Client-Host'   => 'passport.yandex.ru',
        'Ya-Client-Cookie' => $cookie_header,
        'Content-Type'     => 'application/x-www-form-urlencoded',
    );
    $xtoken_req->content(_encode_form_data({
        client_id     => PASSPORT_CLIENT_ID,
        client_secret => PASSPORT_CLIENT_SECRET,
    }));

    my $xtoken_res = $ua->request($xtoken_req);
    my $xtoken_json = _parse_json_response($xtoken_res->content);
    unless ($xtoken_res->is_success && $xtoken_json && $xtoken_json->{access_token}) {
        delete $ACTIVE_SESSIONS{$track_id};
        my $err = _format_error_message($xtoken_json, $xtoken_res, 'Exchange cookies for x_token failed');
        return {
            status  => 'error',
            error   => 'token_by_sessionid_failed',
            message => "Exchange cookies for x_token failed: $err",
        };
    }

    my $x_token = $xtoken_json->{access_token};

    # Step 7: Exchange x_token for music token
    my $music_res = eval { $class->exchange_x_token_sync($x_token) };
    if ($@ || !$music_res || !$music_res->{access_token}) {
        delete $ACTIVE_SESSIONS{$track_id};
        my $err = $@ || 'Failed to exchange x_token for music token';
        $err =~ s/\n+$//;
        return {
            status  => 'error',
            error   => 'music_token_failed',
            message => $err,
        };
    }

    my $music_token = $music_res->{access_token};
    delete $ACTIVE_SESSIONS{$track_id};

    return {
        status       => 'ok',
        access_token => $music_token,
        x_token      => $x_token,
        expires_in   => $music_res->{expires_in} || 31536000,
    };
}

# Exchange long-lived x_token for music-scoped OAuth access token
sub exchange_x_token_sync {
    my ($class, $x_token) = @_;
    unless ($x_token) {
        die "x_token is required\n";
    }

    my $ua = _get_ua();
    my $music_req = HTTP::Request->new(POST => MUSIC_TOKEN_URL);
    $music_req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $music_req->content(_encode_form_data({
        grant_type    => 'x-token',
        access_token  => $x_token,
        client_id     => MUSIC_CLIENT_ID,
        client_secret => MUSIC_CLIENT_SECRET,
    }));

    my $music_res = $ua->request($music_req);
    my $music_json = _parse_json_response($music_res->content);
    unless ($music_res->is_success && $music_json && $music_json->{access_token}) {
        my $err = _format_error_message($music_json, $music_res, 'Exchange x_token for music token failed');
        die "Exchange x_token for music token failed: $err\n";
    }

    return {
        access_token => $music_json->{access_token},
        expires_in   => $music_json->{expires_in} || 31536000,
    };
}

# -------------------------------------------------------------------------
# Asynchronous Entry Points (LMS Event Loop compatible)
# -------------------------------------------------------------------------

sub start_qr_login {
    my ($class, $callback, $error_callback, %args) = @_;

    my $res = eval { $class->start_qr_login_sync(%args) };
    if ($@ || !$res) {
        $error_callback->($@ || "Failed to start QR login");
    } else {
        $callback->($res);
    }
}

sub poll_qr_token {
    my ($class, $track_id, $callback, $error_callback, %args) = @_;

    my $res = eval { $class->poll_qr_token_sync($track_id, %args) };
    if ($@ || !$res) {
        $error_callback->($@ || "Failed to poll QR token");
    } else {
        $callback->($res);
    }
}

sub refresh_access_token {
    my ($class, $x_token, $callback, $error_callback) = @_;

    my $res = eval { $class->exchange_x_token_sync($x_token) };
    if ($@ || !$res) {
        $error_callback->($@ || "Failed to refresh token via x_token");
    } else {
        $callback->($res);
    }
}

sub cancel_qr_login {
    my ($class, $track_id) = @_;
    if ($track_id && exists $ACTIVE_SESSIONS{$track_id}) {
        delete $ACTIVE_SESSIONS{$track_id};
        return 1;
    }
    return 0;
}

1;
