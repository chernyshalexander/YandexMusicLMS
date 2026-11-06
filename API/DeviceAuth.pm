package Plugins::yandex::API::DeviceAuth;

=encoding utf8

=head1 NAME

Plugins::yandex::API::DeviceAuth - OAuth 2.0 Device Authorization Grant for Yandex Music

=head1 DESCRIPTION

Implements Yandex Passport OAuth Device Flow (RFC 8628) as the primary
authentication and authorization mechanism for the LMS Yandex Music plugin.
Allows headless and remote devices (like Logitech/Lyrion Media Server) to
authenticate users without requiring manual token extraction or webview scraping.

=head1 ENDPOINTS

=over 4

=item * POST C<https://oauth.yandex.ru/device/code> - Request device & user code

=item * POST C<https://oauth.yandex.ru/token> - Poll for token / refresh token

=back

=cut

use strict;
use warnings;
use utf8;

use URI;
use URI::Escape qw(uri_escape_utf8);
use Scalar::Util qw(blessed);

# JSON decoder support (LMS JSON::XS or core JSON::PP)
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

# Public OAuth credentials for official Yandex Music Android app
use constant CLIENT_ID           => '23cabbbdc6cd418abb4b39c32c41195d';
use constant CLIENT_SECRET       => '53bc75238f0c4d08a118e51fe9203300';
use constant OAUTH_BASE_URL      => 'https://oauth.yandex.ru';
use constant DEFAULT_DEVICE_NAME => 'Lyrion Music Server';

# Generate a random alphanumeric string for device_id
sub _generate_device_id {
    my $length = shift || 16;
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $id = '';
    $id .= $chars[int(rand(@chars))] for 1..$length;
    return $id;
}

# Encode hash parameters as application/x-www-form-urlencoded
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

# Parse HTTP response content safely into a perl data structure
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

# Safely extract HTTP response body without crashing on non-object error arguments
sub _extract_content {
    my ($res, $h) = @_;
    if ($res && blessed($res) && $res->can('content')) {
        return eval { $res->content } // '';
    }
    if ($h && blessed($h) && $h->can('content')) {
        return eval { $h->content } // '';
    }
    return '';
}

# Safely extract HTTP status code
sub _extract_code {
    my ($res, $h) = @_;
    if ($res && blessed($res) && $res->can('code')) {
        return eval { $res->code } // 0;
    }
    if ($h && blessed($h) && $h->can('code')) {
        return eval { $h->code } // 0;
    }
    return 0;
}

# -----------------------------------------------------------------------------------------
# ASYNCHRONOUS API METHODS (LMS Event Loop)
# -----------------------------------------------------------------------------------------

=head2 request_device_code( $callback, $error_callback, %args )

Asynchronously request a device code and user verification code from Yandex OAuth.

Arguments:
- C<$callback>: sub($device_code_data) { ... } called on success.
  Receives hash ref: C<{ device_code, user_code, verification_url, expires_in, interval }>
- C<$error_callback>: sub($error_message) { ... } called on failure.
- C<%args>: Optional overrides (client_id, device_id, device_name).

=cut

sub request_device_code {
    my ($class, $callback, $error_callback, %args) = @_;

    my $client_id   = $args{client_id}   || CLIENT_ID;
    my $device_id   = $args{device_id}   || _generate_device_id();
    my $device_name = $args{device_name} || DEFAULT_DEVICE_NAME;

    my $url = OAUTH_BASE_URL . '/device/code';
    my $body = _encode_form_data({
        client_id   => $client_id,
        device_id   => $device_id,
        device_name => $device_name,
    });

    # Check if LMS SimpleAsyncHTTP is available
    if (eval { require Slim::Networking::SimpleAsyncHTTP; 1; }) {
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $h = shift;
                my $content = $h->content;
                my $json = _parse_json_response($content);
                if ($json && $json->{device_code} && $json->{user_code}) {
                    $callback->({
                        device_code      => $json->{device_code},
                        user_code        => $json->{user_code},
                        verification_url => $json->{verification_url} || 'https://ya.ru/device',
                        expires_in       => int($json->{expires_in} || 300),
                        interval         => int($json->{interval} || 5),
                    });
                } elsif ($json && $json->{error}) {
                    $error_callback->($json->{error_description} || $json->{error});
                } else {
                    $error_callback->("Invalid response from Yandex OAuth: " . ($content || 'empty response'));
                }
            },
            sub {
                my ($h, $error, $res) = @_;
                my $content = _extract_content($res, $h);
                my $json = _parse_json_response($content);
                if ($json && $json->{error}) {
                    $error_callback->($json->{error_description} || $json->{error});
                } else {
                    $error_callback->($error || 'Network error requesting device code');
                }
            }
        );

        $http->post(
            $url,
            'User-Agent'   => 'Yandex-Music-API',
            'Content-Type' => 'application/x-www-form-urlencoded',
            'Accept'       => 'application/json',
            $body
        );
    } else {
        # Fallback to sync execution in standalone/test environments
        my $res = eval { $class->request_device_code_sync(%args) };
        if ($@ || !$res) {
            $error_callback->($@ || "Failed to request device code");
        } else {
            $callback->($res);
        }
    }
}

=head2 poll_device_token( $device_code, $callback, $error_callback, %args )

Asynchronously perform a single poll check for the device code.

Status results passed to C<$callback>:
- C<{ status => 'pending' }>: User has not authorized yet.
- C<{ status => 'ok', access_token => '...', refresh_token => '...', expires_in => ... }>: Successful authorization.
- C<{ status => 'error', error => '...', error_description => '...' }>: Terminal error (expired_token, invalid_grant, access_denied, etc.).

=cut

sub poll_device_token {
    my ($class, $device_code, $callback, $error_callback, %args) = @_;

    unless ($device_code) {
        $error_callback->("Device code is required");
        return;
    }

    # RFC 8628 OAuth 2.0 Device Flow:
    # When authorization is pending, Yandex returns HTTP 400 with {"error": "authorization_pending"}.
    # LMS Slim::Networking::Async::HTTP drops connections on status !~ /[23]\d\d/ before reading body.
    # Therefore, SimpleAsyncHTTP loses the response body on 400.
    # We use LWP::UserAgent (via poll_device_token_sync), which preserves the full HTTP 400 JSON body.
    my $res = eval { $class->poll_device_token_sync($device_code, %args) };
    if ($@) {
        $error_callback->($@);
    } elsif (!$res) {
        $error_callback->("Failed to poll device token");
    } else {
        $callback->($res);
    }
}

=head2 refresh_access_token( $refresh_token, $callback, $error_callback, %args )

Asynchronously refresh an existing OAuth token using its refresh_token.

=cut

sub refresh_access_token {
    my ($class, $refresh_token, $callback, $error_callback, %args) = @_;

    unless ($refresh_token) {
        $error_callback->("Refresh token is required");
        return;
    }

    my $res = eval { $class->refresh_access_token_sync($refresh_token, %args) };
    if ($@) {
        $error_callback->($@);
    } elsif (!$res) {
        $error_callback->("Failed to refresh token");
    } else {
        $callback->($res);
    }
}

# -----------------------------------------------------------------------------------------
# SYNCHRONOUS / BLOCKING METHODS (For tests, scanner, or CLI scripts)
# -----------------------------------------------------------------------------------------

sub _get_ua {
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        timeout => 15,
        ssl_opts => { verify_hostname => 1 },
    );
    $ua->default_header('User-Agent' => 'Yandex-Music-API');
    $ua->default_header('Accept'     => 'application/json');
    return $ua;
}

sub request_device_code_sync {
    my ($class, %args) = @_;

    my $client_id   = $args{client_id}   || CLIENT_ID;
    my $device_id   = $args{device_id}   || _generate_device_id();
    my $device_name = $args{device_name} || DEFAULT_DEVICE_NAME;

    my $ua = _get_ua();
    my $res = $ua->post(OAUTH_BASE_URL . '/device/code', {
        client_id   => $client_id,
        device_id   => $device_id,
        device_name => $device_name,
    });

    my $json = _parse_json_response($res->content);
    if ($res->is_success && $json && $json->{device_code}) {
        return {
            device_code      => $json->{device_code},
            user_code        => $json->{user_code},
            verification_url => $json->{verification_url} || 'https://ya.ru/device',
            expires_in       => int($json->{expires_in} || 300),
            interval         => int($json->{interval} || 5),
        };
    }

    my $err = $json && $json->{error_description} ? $json->{error_description} : $res->status_line;
    die "Device code request failed: $err\n";
}

sub poll_device_token_sync {
    my ($class, $device_code, %args) = @_;

    die "device_code is required\n" unless $device_code;

    my $client_id     = $args{client_id}     || CLIENT_ID;
    my $client_secret = $args{client_secret} || CLIENT_SECRET;

    my $ua = _get_ua();
    my $res = $ua->post(OAUTH_BASE_URL . '/token', {
        grant_type    => 'device_code',
        code          => $device_code,
        client_id     => $client_id,
        client_secret => $client_secret,
    });

    my $json = _parse_json_response($res->content);
    if ($res->is_success && $json && $json->{access_token}) {
        return {
            status        => 'ok',
            access_token  => $json->{access_token},
            refresh_token => $json->{refresh_token} || '',
            expires_in    => int($json->{expires_in} || 0),
            token_type    => $json->{token_type} || 'bearer',
        };
    }

    if ($json && $json->{error}) {
        if ($json->{error} eq 'authorization_pending') {
            return {
                status            => 'pending',
                error             => $json->{error},
                error_description => $json->{error_description} || 'Authorization pending',
            };
        }
        return {
            status            => 'error',
            error             => $json->{error},
            error_description => $json->{error_description} || $json->{error},
        };
    }

    die "Poll token request failed: " . $res->status_line . "\n";
}

sub refresh_access_token_sync {
    my ($class, $refresh_token, %args) = @_;

    die "refresh_token is required\n" unless $refresh_token;

    my $client_id     = $args{client_id}     || CLIENT_ID;
    my $client_secret = $args{client_secret} || CLIENT_SECRET;

    my $ua = _get_ua();
    my $res = $ua->post(OAUTH_BASE_URL . '/token', {
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
        client_id     => $client_id,
        client_secret => $client_secret,
    });

    my $json = _parse_json_response($res->content);
    if ($res->is_success && $json && $json->{access_token}) {
        return {
            access_token  => $json->{access_token},
            refresh_token => $json->{refresh_token} || $refresh_token,
            expires_in    => int($json->{expires_in} || 0),
        };
    }

    my $err = $json && $json->{error_description} ? $json->{error_description} : $res->status_line;
    die "Refresh token request failed: $err\n";
}

=head2 device_auth_sync( %args )

Blocking helper executing full OAuth Device Flow:
1. Requests device code
2. Calls C<$args{on_code}->($code_data)>
3. Polls until user confirms, timeout expires, or C<$args{should_cancel}->()> returns true.

=cut

sub device_auth_sync {
    my ($class, %args) = @_;

    my $on_code = $args{on_code} || sub {
        my $c = shift;
        print "Please visit: $c->{verification_url}\n";
        print "Enter code:   $c->{user_code}\n";
    };

    my $code_data = $class->request_device_code_sync(%args);
    $on_code->($code_data);

    my $interval = defined $args{poll_interval} ? $args{poll_interval} : ($code_data->{interval} // 5);
    my $timeout  = defined $args{timeout}       ? $args{timeout}       : ($code_data->{expires_in} // 300);
    my $deadline = time() + $timeout;

    while (time() < $deadline) {
        if ($args{should_cancel} && $args{should_cancel}->()) {
            die "Device auth cancelled by caller\n";
        }

        my $poll = $class->poll_device_token_sync($code_data->{device_code}, %args);
        if ($poll->{status} eq 'ok') {
            return $poll;
        } elsif ($poll->{status} eq 'error') {
            die "Device auth error: " . ($poll->{error_description} || $poll->{error}) . "\n";
        }

        # Pending -> sleep for interval
        sleep($interval);
    }

    die "Device auth timed out after ${timeout}s\n";
}

1;
