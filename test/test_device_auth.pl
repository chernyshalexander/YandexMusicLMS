#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib '.';
use lib '/usr/share/squeezeboxserver/CPAN';
use Test::More 'no_plan';

# Mock Slim framework and environment for standalone execution
BEGIN {
    for my $c (qw(SCANNER PERFMON DEBUGLOG INFOLOG STATISTICS ISWINDOWS ISMAC RESIZER WEBUI NOMYSB TRANSCODING SB1SLIMP3SYNC LOCALFILE NOBROWSECACHE SLIM_SERVICE NOUPNP ISACTIVEPERL HAS_AIO)) {
        no strict "refs"; *{"main::$c"} = sub () { 0 };
    }

    $INC{"Slim/Utils/Log.pm"} = 1;
    {
        package MockLog;
        sub info {} sub error {} sub warn {} sub debug {} sub is_debug { 0 } sub is_info { 0 }
        package Slim::Utils::Log;
        sub logger { bless {}, 'MockLog' }
        sub addLogCategory { bless {}, 'MockLog' }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::logger"} = \&logger;
        }
    }

    $INC{"Slim/Utils/Prefs.pm"} = 1;
    {
        package MockPrefs;
        my %storage;
        sub new { bless {}, shift }
        sub get { my ($self, $k) = @_; return $storage{$k}; }
        sub set { my ($self, $k, $v) = @_; $storage{$k} = $v; return 1; }
        sub client { my ($self, $client) = @_; return $self; }
        sub remove { my ($self, $k) = @_; delete $storage{$k}; }
        sub reset_all { %storage = (); }

        package Slim::Utils::Prefs;
        our $instance = MockPrefs->new;
        sub preferences { return $instance; }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::preferences"} = \&preferences;
        }
    }

    $INC{"Slim/Utils/Strings.pm"} = 1;
    {
        package Slim::Utils::Strings;
        sub string { return $_[0]; }
        sub cstring { return $_[1]; }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::string"} = \&string;
            *{"${caller}::cstring"} = \&cstring;
        }
    }

    $INC{"Slim/Utils/Cache.pm"} = 1;
    $INC{"Slim/Utils/DbCache.pm"} = 1;
    {
        package Slim::Utils::Cache;
        our %DATA;
        sub new { bless {}, shift }
        sub get { my ($s, $k) = @_; return $DATA{$k} }
        sub set { my ($s, $k, $v) = @_; $DATA{$k} = $v }
        sub remove { my ($s, $k) = @_; delete $DATA{$k} }
        package Slim::Utils::DbCache;
        sub new { bless {}, shift }
    }

    $INC{"Slim/Networking/SimpleAsyncHTTP.pm"} = 1;
    {
        package MockAsyncResponse;
        sub new {
            my ($class, $code, $content) = @_;
            bless { code => $code, content => $content }, $class;
        }
        sub code { $_[0]->{code} }
        sub content { $_[0]->{content} }

        package Slim::Networking::SimpleAsyncHTTP;
        our @queue;
        sub new {
            my ($class, $cb, $ecb, $params) = @_;
            bless { cb => $cb, ecb => $ecb, params => $params }, $class;
        }
        sub code { $_[0]->{_resp} ? $_[0]->{_resp}->code : 200 }
        sub content { $_[0]->{_resp} ? $_[0]->{_resp}->content : '' }
        sub get {}
        sub post {
            my ($self, $url, @args) = @_;
            my $item = shift @queue;
            return unless $item;
            $self->{_resp} = $item->{resp};
            if ($item->{type} eq 'success') {
                $self->{cb}->($self);
            } else {
                $self->{ecb}->($self, $item->{error}, $item->{resp});
            }
        }
    }

    $INC{"Slim/Web/Settings.pm"} = 1;
    {
        package Slim::Web::Settings;
        sub new { bless {}, shift }
        sub page { 'plugins/yandex/settings/basic.html' }
        sub name { 'PLUGIN_YANDEX' }
        sub prefs { return () }
        sub beforeRender {}
        sub handler {
            my ($class, $client, $params) = @_;
            return \"<html>Settings Rendered</html>";
        }
    }

    # Hook @INC to load Plugins/yandex/* from current repo
    unshift @INC, sub {
        my ($self, $file) = @_;
        if ($file =~ s{^Plugins/yandex/}{}) {
            open my $fh, "<", $file or return undef;
            return $fh;
        }
        return undef;
    };
}

# Load tested modules
require Plugins::yandex::API::DeviceAuth;
require Plugins::yandex::API::QRAuth;
require Plugins::yandex::Settings;

BEGIN {
    eval {
        require JSON::XS::VersionOneAndTwo;
        1;
    } || eval {
        require JSON::PP;
        JSON::PP->import(qw(encode_json decode_json to_json from_json));
        1;
    };
}

my $prefs = Slim::Utils::Prefs::preferences();
$prefs->reset_all();

# =========================================================================
# 1. DeviceAuth module constants and helpers
# =========================================================================
is(Plugins::yandex::API::DeviceAuth->CLIENT_ID, '23cabbbdc6cd418abb4b39c32c41195d', 'CLIENT_ID matches official Android app id');
is(Plugins::yandex::API::DeviceAuth->CLIENT_SECRET, '53bc75238f0c4d08a118e51fe9203300', 'CLIENT_SECRET matches default secret');
is(Plugins::yandex::API::DeviceAuth->OAUTH_BASE_URL, 'https://oauth.yandex.ru', 'OAUTH_BASE_URL matches Yandex OAuth host');

my $dev_id1 = Plugins::yandex::API::DeviceAuth::_generate_device_id();
my $dev_id2 = Plugins::yandex::API::DeviceAuth::_generate_device_id();
is(length($dev_id1), 16, '_generate_device_id defaults to 16 characters');
like($dev_id1, qr/^[a-zA-Z0-9]{16}$/, '_generate_device_id is alphanumeric');
isnt($dev_id1, $dev_id2, '_generate_device_id generates unique random strings');

my $dev_id_custom = Plugins::yandex::API::DeviceAuth::_generate_device_id(24);
is(length($dev_id_custom), 24, '_generate_device_id respects custom length');

# =========================================================================
# 2. Synchronous & Asynchronous DeviceAuth Mock Tests
# =========================================================================

# Test Mock HTTP Response
{
    package MockHTTPResponse;
    sub new {
        my ($class, $code, $content, $is_success) = @_;
        bless { code => $code, content => $content, is_success => $is_success }, $class;
    }
    sub code { $_[0]->{code} }
    sub content { $_[0]->{content} }
    sub is_success { $_[0]->{is_success} }
    sub status_line { "$_[0]->{code} Mock Status" }
}

# Test Mock UserAgent for sync methods
{
    package MockUA;
    our @responses;
    our @calls;
    sub new { bless { jar => $_[1] }, $_[0] }
    sub default_header {}
    sub agent {}
    sub cookie_jar {
        my ($self, $jar) = @_;
        $self->{jar} = $jar if $jar;
        return $self->{jar};
    }
    sub post {
        my ($self, $url, $form) = @_;
        push @calls, { method => 'POST', url => $url, form => $form };
        my $resp = shift @responses;
        die "No mock response configured in MockUA\n" unless $resp;
        return $resp;
    }
    sub get {
        my ($self, $url) = @_;
        push @calls, { method => 'GET', url => $url };
        my $resp = shift @responses;
        die "No mock response configured in MockUA\n" unless $resp;
        return $resp;
    }
    sub request {
        my ($self, $req) = @_;
        push @calls, { method => $req->method, url => $req->uri->as_string, req => $req };
        my $resp = shift @responses;
        die "No mock response configured in MockUA\n" unless $resp;
        return $resp;
    }
}

# Override _get_ua for testing sync methods
no warnings 'redefine';
*Plugins::yandex::API::DeviceAuth::_get_ua = sub {
    return MockUA->new;
};
*Plugins::yandex::API::QRAuth::_get_ua = sub {
    my ($jar) = @_;
    return MockUA->new($jar);
};
use warnings 'redefine';

# Test request_device_code_sync
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            device_code      => 'dev12345',
            user_code        => 'abcd-efgh',
            verification_url => 'https://ya.ru/device',
            expires_in       => 300,
            interval         => 5,
        }), 1)
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::DeviceAuth->request_device_code_sync(device_name => 'TestLMS');
    is($res->{device_code}, 'dev12345', 'request_device_code_sync parses device_code');
    is($res->{user_code}, 'abcd-efgh', 'request_device_code_sync parses user_code');
    is($res->{verification_url}, 'https://ya.ru/device', 'request_device_code_sync parses verification_url');
    is($res->{expires_in}, 300, 'request_device_code_sync parses expires_in');
    is($res->{interval}, 5, 'request_device_code_sync parses interval');

    is(scalar(@MockUA::calls), 1, 'MockUA recorded 1 POST request');
    is($MockUA::calls[0]->{url}, 'https://oauth.yandex.ru/device/code', 'Target URL is /device/code');
    is($MockUA::calls[0]->{form}->{client_id}, '23cabbbdc6cd418abb4b39c32c41195d', 'client_id transmitted in form');
    is($MockUA::calls[0]->{form}->{device_name}, 'TestLMS', 'device_name transmitted in form');
}

# Test poll_device_token_sync (pending)
{
    @MockUA::responses = (
        MockHTTPResponse->new(400, encode_json({
            error             => 'authorization_pending',
            error_description => 'User has not yet authorized your application',
        }), 0)
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::DeviceAuth->poll_device_token_sync('dev12345');
    is($res->{status}, 'pending', 'poll_device_token_sync identifies authorization_pending');
    is($res->{error}, 'authorization_pending', 'poll_device_token_sync returns error code');
    is($MockUA::calls[0]->{url}, 'https://oauth.yandex.ru/token', 'Target URL is /token');
    is($MockUA::calls[0]->{form}->{grant_type}, 'device_code', 'grant_type is device_code');
    is($MockUA::calls[0]->{form}->{code}, 'dev12345', 'device_code passed as code');
}

# Test poll_device_token_sync (success)
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'y0_access_token_123',
            refresh_token => '1:refresh_token_456',
            expires_in    => 31536000,
            token_type    => 'bearer',
        }), 1)
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::DeviceAuth->poll_device_token_sync('dev12345');
    is($res->{status}, 'ok', 'poll_device_token_sync returns status ok on success');
    is($res->{access_token}, 'y0_access_token_123', 'access_token parsed');
    is($res->{refresh_token}, '1:refresh_token_456', 'refresh_token parsed');
    is($res->{expires_in}, 31536000, 'expires_in parsed');
}

# Test poll_device_token_sync (error: expired / access_denied)
{
    @MockUA::responses = (
        MockHTTPResponse->new(400, encode_json({
            error             => 'invalid_grant',
            error_description => 'Code has expired',
        }), 0)
    );

    my $res = Plugins::yandex::API::DeviceAuth->poll_device_token_sync('dev12345');
    is($res->{status}, 'error', 'poll_device_token_sync returns status error on invalid_grant');
    is($res->{error}, 'invalid_grant', 'error code matches');
    is($res->{error_description}, 'Code has expired', 'error description matches');
}

# Test refresh_access_token_sync
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'y0_new_access_token',
            refresh_token => '1:new_refresh_token',
            expires_in    => 31536000,
        }), 1)
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::DeviceAuth->refresh_access_token_sync('1:old_refresh_token');
    is($res->{access_token}, 'y0_new_access_token', 'refresh_access_token_sync returns new access token');
    is($res->{refresh_token}, '1:new_refresh_token', 'refresh_access_token_sync returns rotated refresh token');
    is($MockUA::calls[0]->{form}->{grant_type}, 'refresh_token', 'grant_type is refresh_token');
    is($MockUA::calls[0]->{form}->{refresh_token}, '1:old_refresh_token', 'refresh_token passed in form');
}

# Test device_auth_sync (blocking flow: start -> pending -> success)
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            device_code      => 'dev_flow_99',
            user_code        => 'flow-code',
            verification_url => 'https://ya.ru/device',
            expires_in       => 60,
            interval         => 0,
        }), 1),
        MockHTTPResponse->new(400, encode_json({
            error             => 'authorization_pending',
            error_description => 'Pending',
        }), 0),
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'y0_flow_access',
            refresh_token => '1:flow_refresh',
            expires_in    => 31536000,
            token_type    => 'bearer',
        }), 1),
    );

    my $captured_code;
    my $res = Plugins::yandex::API::DeviceAuth->device_auth_sync(
        poll_interval => 0,
        on_code => sub {
            my $c = shift;
            $captured_code = $c->{user_code};
        }
    );

    is($captured_code, 'flow-code', 'device_auth_sync on_code callback triggered');
    is($res->{status}, 'ok', 'device_auth_sync returned status ok');
    is($res->{access_token}, 'y0_flow_access', 'device_auth_sync returned token');
}

# Test device_auth_sync (cancellation via should_cancel)
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            device_code      => 'dev_cancel',
            user_code        => 'cancel-code',
            verification_url => 'https://ya.ru/device',
            expires_in       => 60,
            interval         => 0,
        }), 1),
    );

    my $res = eval {
        Plugins::yandex::API::DeviceAuth->device_auth_sync(
            poll_interval => 0,
            should_cancel => sub { 1 },
        );
    };
    like($@, qr/cancelled/i, 'device_auth_sync aborts when should_cancel is true');
}

# =========================================================================
# 2b. Asynchronous DeviceAuth SimpleAsyncHTTP Tests
# =========================================================================

# Test request_device_code (async success)
{
    @Slim::Networking::SimpleAsyncHTTP::queue = (
        {
            type => 'success',
            resp => MockAsyncResponse->new(200, encode_json({
                device_code      => 'async_dev_100',
                user_code        => 'async_usr_100',
                verification_url => 'https://ya.ru/device',
                expires_in       => 300,
                interval         => 5,
            })),
        }
    );

    my ($success_res, $err_res);
    Plugins::yandex::API::DeviceAuth->request_device_code(
        sub { $success_res = shift },
        sub { $err_res = shift }
    );

    ok($success_res, 'request_device_code async success callback triggered');
    is($success_res->{device_code}, 'async_dev_100', 'async device_code matches');
    is($success_res->{user_code}, 'async_usr_100', 'async user_code matches');
    is($success_res->{interval}, 5, 'async interval matches');
    ok(!$err_res, 'no error on async success');
}

# Test request_device_code (async error handling with unblessed scalar response)
{
    @Slim::Networking::SimpleAsyncHTTP::queue = (
        {
            type  => 'error',
            error => 'Connection refused',
            resp  => 'plain error string', # Non-blessed scalar, tests safe error handling!
        }
    );

    my ($success_res, $err_res);
    eval {
        Plugins::yandex::API::DeviceAuth->request_device_code(
            sub { $success_res = shift },
            sub { $err_res = shift }
        );
    };
    is($@, '', 'request_device_code does not crash on non-object error response');
    ok(!$success_res, 'success callback not invoked on network error');
    like($err_res, qr/Connection refused/i, 'error callback received error description');
}

# Test poll_device_token (async pending)
{
    @MockUA::responses = (
        MockHTTPResponse->new(400, encode_json({
            error             => 'authorization_pending',
            error_description => 'Pending',
        }), 0),
    );

    my ($success_res, $err_res);
    Plugins::yandex::API::DeviceAuth->poll_device_token(
        'async_dev_100',
        sub { $success_res = shift },
        sub { $err_res = shift }
    );

    ok($success_res, 'poll_device_token pending calls callback');
    is($success_res->{status}, 'pending', 'status is pending');
}

# Test poll_device_token (async ok with token & refresh_token)
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'async_tok_100',
            refresh_token => 'async_ref_100',
            expires_in    => 31536000,
            token_type    => 'bearer',
        }), 1),
    );

    my ($success_res, $err_res);
    Plugins::yandex::API::DeviceAuth->poll_device_token(
        'async_dev_100',
        sub { $success_res = shift },
        sub { $err_res = shift }
    );

    ok($success_res, 'poll_device_token ok calls callback');
    is($success_res->{status}, 'ok', 'status is ok');
    is($success_res->{access_token}, 'async_tok_100', 'access_token matches');
    is($success_res->{refresh_token}, 'async_ref_100', 'refresh_token matches');
}

# Test poll_device_token (async error: expired_token)
{
    @MockUA::responses = (
        MockHTTPResponse->new(400, encode_json({
            error             => 'expired_token',
            error_description => 'Token has expired',
        }), 0),
    );

    my ($success_res, $err_res);
    Plugins::yandex::API::DeviceAuth->poll_device_token(
        'async_dev_100',
        sub { $success_res = shift },
        sub { $err_res = shift }
    );

    ok($success_res, 'poll_device_token error status returned to callback');
    is($success_res->{status}, 'error', 'status is error');
    is($success_res->{error}, 'expired_token', 'error code is expired_token');
}

# Test refresh_access_token (async success)
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'refreshed_tok_200',
            refresh_token => 'new_refresh_200',
            expires_in    => 31536000,
        }), 1),
    );

    my ($success_res, $err_res);
    Plugins::yandex::API::DeviceAuth->refresh_access_token(
        'old_refresh_100',
        sub { $success_res = shift },
        sub { $err_res = shift }
    );

    ok($success_res, 'refresh_access_token async success');
    is($success_res->{access_token}, 'refreshed_tok_200', 'refreshed access_token received');
    is($success_res->{refresh_token}, 'new_refresh_200', 'new refresh_token received');
}

# =========================================================================
# 3. Settings.pm Device Flow Request Handling
# =========================================================================

# Test Mock Plugin API Client initialization hook
{
    package Plugins::yandex::Plugin;
    our %initialized_clients;
    our %removed_clients;
    sub _init_api_client {
        my $uid = shift;
        $initialized_clients{$uid} = 1;
    }
    sub _remove_api_client {
        my $uid = shift;
        $removed_clients{$uid} = 1;
    }
}

# Mock API::Async for token validation in Settings.pm
$INC{"Plugins/yandex/API/Async.pm"} = 1;
{
    package Plugins::yandex::API::Async;
    our $mock_init_success = 1;
    our $mock_uid = 99887766;
    our $mock_login = 'yandex_user_test';
    our $mock_name = 'Test User';

    sub new {
        my ($class, $token) = @_;
        bless { token => $token }, $class;
    }
    sub init {
        my ($self, $cb, $ecb) = @_;
        if ($mock_init_success) {
            $self->{me} = {
                uid         => $mock_uid,
                login       => $mock_login,
                displayName => $mock_name,
            };
            $cb->($self);
        } else {
            $ecb->("Invalid mock token");
        }
    }
    sub check_dependencies {
        return { rijndael => 1, ffmpeg => 1 };
    }
}

# Test Settings device_action=start
{
    no warnings qw(redefine once);
    *Plugins::yandex::API::DeviceAuth::request_device_code = sub {
        my ($class, $cb, $ecb, %args) = @_;
        $cb->({
            device_code      => 'dev_start_123',
            user_code        => 'xyz123',
            verification_url => 'https://ya.ru/device',
            expires_in       => 300,
            interval         => 5,
        });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { device_action => 'start' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for device_action=start');
    is($received_json->{success}, 1, 'Response has success=1');
    is($received_json->{user_code}, 'xyz123', 'Response contains user_code');
    is($received_json->{device_code}, 'dev_start_123', 'Response contains device_code');
    is($received_json->{verification_url}, 'https://ya.ru/device', 'Response contains verification_url');
}

# Test Settings device_action=poll (pending)
{
    no warnings 'redefine';
    *Plugins::yandex::API::DeviceAuth::poll_device_token = sub {
        my ($class, $code, $cb, $ecb, %args) = @_;
        $cb->({ status => 'pending' });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { device_action => 'poll', device_code => 'dev_start_123' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for device_action=poll pending');
    is($received_json->{status}, 'pending', 'Response status is pending');
}

# Test Settings device_action=poll (success & account persistence)
{
    no warnings 'redefine';
    *Plugins::yandex::API::DeviceAuth::poll_device_token = sub {
        my ($class, $code, $cb, $ecb, %args) = @_;
        $cb->({
            status        => 'ok',
            access_token  => 'y0_authorized_token_xyz',
            refresh_token => '1:authorized_refresh_xyz',
            expires_in    => 31536000,
        });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { device_action => 'poll', device_code => 'dev_start_123' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for device_action=poll success');
    is($received_json->{status}, 'ok', 'Response status is ok');
    is($received_json->{userId}, 99887766, 'Response contains userId');
    is($received_json->{login}, 'yandex_user_test', 'Response contains login');

    # Verify stored account in preferences
    my $accounts = $prefs->get('accounts');
    ok(exists $accounts->{99887766}, 'Account stored in preferences by userId');
    is($accounts->{99887766}->{uid}, 99887766, 'uid saved in account for scanner and background tasks');
    is($accounts->{99887766}->{token}, 'y0_authorized_token_xyz', 'access_token saved in account');
    is($accounts->{99887766}->{refresh_token}, '1:authorized_refresh_xyz', 'refresh_token saved in account');
    is($accounts->{99887766}->{auth_method}, 'device_code', 'auth_method recorded as device_code');
    is($accounts->{99887766}->{login}, 'yandex_user_test', 'login saved in account');
    ok($Plugins::yandex::Plugin::initialized_clients{99887766}, 'Plugin::_init_api_client was called for the new account');
}

# Test Settings device_action=poll: re-authorizing existing account purges stale client
{
    $Plugins::yandex::Plugin::removed_clients{99887766} = 0;
    $Plugins::yandex::Plugin::initialized_clients{99887766} = 0;

    no warnings 'redefine';
    *Plugins::yandex::API::DeviceAuth::poll_device_token = sub {
        my ($class, $code, $cb, $ecb, %args) = @_;
        $cb->({
            status        => 'ok',
            access_token  => 'y0_rotated_token_new',
            refresh_token => '1:rotated_refresh_new',
            expires_in    => 31536000,
        });
    };
    use warnings 'redefine';

    my $callback = sub {};
    Plugins::yandex::Settings->handler(undef, { device_action => 'poll', device_code => 'dev_reauth_1' }, $callback);

    my $accounts = $prefs->get('accounts');
    is($accounts->{99887766}->{token}, 'y0_rotated_token_new', 'Re-auth updated access_token');
    is($accounts->{99887766}->{refresh_token}, '1:rotated_refresh_new', 'Re-auth updated refresh_token');
    ok($Plugins::yandex::Plugin::removed_clients{99887766}, 'Existing cached client removed before re-initialization');
    ok($Plugins::yandex::Plugin::initialized_clients{99887766}, 'Plugin::_init_api_client re-run for updated account');
}

# Test Settings device_action=poll (missing device_code error)
{
    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { device_action => 'poll' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback on missing device_code');
    is($received_json->{status}, 'error', 'Error status returned');
    is($received_json->{error}, 'missing_device_code', 'missing_device_code error code returned');
}

# Test Settings device_action=cancel
{
    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { device_action => 'cancel' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback on cancel');
    is($received_json->{status}, 'cancelled', 'cancelled status returned');
}

# =========================================================================
# 4. Backward Compatibility: Fallback Auth Methods Still Work
# =========================================================================

# Test fallback 1: Manual token entry via new_account_token + saveSettings
{
    $Plugins::yandex::API::Async::mock_uid = 11223344;
    $Plugins::yandex::API::Async::mock_login = 'fallback_user';
    $Plugins::yandex::API::Async::mock_name = 'Fallback User';

    my $callback_called = 0;
    my $callback = sub {
        my ($client, $params, $body, @args) = @_;
        $callback_called = 1;
    };

    Plugins::yandex::Settings->handler(
        undef,
        {
            saveSettings       => 1,
            new_account_token  => 'manual_secret_token_abc',
        },
        $callback
    );

    is($callback_called, 1, 'Fallback manual token entry callback invoked');
    my $accounts = $prefs->get('accounts');
    ok(exists $accounts->{11223344}, 'Fallback manual account stored in preferences');
    is($accounts->{11223344}->{token}, 'manual_secret_token_abc', 'Manual token correctly saved');
    ok($Plugins::yandex::Plugin::initialized_clients{11223344}, 'Plugin client initialized for manual account');
}

# Test fallback 2: Browser bookmarklet/drag-drop callback via save_token
{
    $Plugins::yandex::API::Async::mock_uid = 55667788;
    $Plugins::yandex::API::Async::mock_login = 'bookmarklet_user';
    $Plugins::yandex::API::Async::mock_name = 'Bookmarklet User';

    my $res_ref = Plugins::yandex::Settings->handler(
        undef,
        {
            save_token => 1,
            token      => 'bookmarklet_token_xyz',
        },
        undef
    );

    like($$res_ref, qr/Authorization successful/i, 'save_token returns HTML success page');
    my $accounts = $prefs->get('accounts');
    ok(exists $accounts->{55667788}, 'Bookmarklet account stored in preferences');
    is($accounts->{55667788}->{token}, 'bookmarklet_token_xyz', 'Bookmarklet token saved');
}

# Test Account Deletion
{
    Plugins::yandex::Settings->handler(
        undef,
        {
            'delete_11223344' => 'Delete',
        },
        undef
    );

    my $accounts = $prefs->get('accounts');
    ok(!exists $accounts->{11223344}, 'Account 11223344 deleted from preferences');
    ok($Plugins::yandex::Plugin::removed_clients{11223344}, 'Plugin client removed for deleted account');
}

# =========================================================================
# 5. Token Refresh Lifecycle (Silent Token Renewal on Expiry)
# =========================================================================
{
    # Simulate an account with expired access token and valid refresh_token
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{'445566'} = {
        token         => 'expired_token_001',
        refresh_token => 'valid_refresh_001',
        login         => 'refresh_user',
        name          => 'Refresh User',
        uid           => '445566',
        auth_method   => 'device_code',
    };
    $prefs->set('accounts', $accounts);

    # Queue mock response for refresh_access_token
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token  => 'refreshed_access_token_999',
            refresh_token => 'refreshed_refresh_token_999',
            expires_in    => 31536000,
        }), 1),
    );

    # Test refresh token execution directly
    my ($refresh_success, $refresh_error);
    Plugins::yandex::API::DeviceAuth->refresh_access_token(
        $accounts->{'445566'}->{refresh_token},
        sub {
            my $res = shift;
            $refresh_success = $res;
            my $accs = $prefs->get('accounts') || {};
            $accs->{'445566'}->{token} = $res->{access_token};
            $accs->{'445566'}->{refresh_token} = $res->{refresh_token};
            $prefs->set('accounts', $accs);
        },
        sub {
            $refresh_error = shift;
        }
    );

    ok($refresh_success, 'Silent refresh succeeded');
    is($refresh_success->{access_token}, 'refreshed_access_token_999', 'refreshed access_token returned');
    my $updated_accs = $prefs->get('accounts');
    is($updated_accs->{'445566'}->{token}, 'refreshed_access_token_999', 'Preferences updated with refreshed access_token');
    is($updated_accs->{'445566'}->{refresh_token}, 'refreshed_refresh_token_999', 'Preferences updated with rotated refresh_token');
}

# =========================================================================
# 6. Regression: Robust JSON parsing when VersionOneAndTwo pre-loaded in %INC
# =========================================================================
# =========================================================================
# 7. Native Yandex Passport QR Login Flow (METHOD_QR)
# =========================================================================

# Test QRAuth constants & helpers
is(Plugins::yandex::API::QRAuth->PASSPORT_CLIENT_ID, 'c0ebe342af7d48fbbbfcf2d2eedb8f9e', 'PASSPORT_CLIENT_ID matches reference implementation');
is(Plugins::yandex::API::QRAuth->PASSPORT_CLIENT_SECRET, 'ad0a908f0aa341a182a37ecd75bc319e', 'PASSPORT_CLIENT_SECRET matches reference implementation');
is(Plugins::yandex::API::QRAuth->MUSIC_CLIENT_ID, '23cabbbdc6cd418abb4b39c32c41195d', 'MUSIC_CLIENT_ID matches official app id');
is(Plugins::yandex::API::QRAuth->MUSIC_CLIENT_SECRET, '53bc75238f0c4d08a118e51fe9203300', 'MUSIC_CLIENT_SECRET matches default secret');
is(Plugins::yandex::API::QRAuth->PWL_URL, 'https://passport.yandex.ru/pwl-yandex', 'PWL_URL matches mobile passport endpoint');

# Test CSRF extraction patterns
{
    my $html1 = '<html><input type="hidden" name="csrf_token" value="test_csrf_token_123"></html>';
    is(Plugins::yandex::API::QRAuth::_extract_csrf($html1), 'test_csrf_token_123', 'extract_csrf matches input value pattern');

    my $html2 = '<script>window.__CSRF__ = "test_csrf_token_456";</script>';
    is(Plugins::yandex::API::QRAuth::_extract_csrf($html2), 'test_csrf_token_456', 'extract_csrf matches window.__CSRF__ pattern');

    my $html3 = "{ 'csrf_token' : 'test_csrf_token_789' }";
    is(Plugins::yandex::API::QRAuth::_extract_csrf($html3), 'test_csrf_token_789', 'extract_csrf matches single-quote json pattern');

    is(Plugins::yandex::API::QRAuth::_extract_csrf('no csrf here'), '', 'extract_csrf returns empty string when not found');
}

# Test start_qr_login_sync
{
    @MockUA::responses = (
        # 1. GET /pwl-yandex
        MockHTTPResponse->new(200, '<html><input type="hidden" name="csrf_token" value="csrf_abc_123"></html>', 1),
        # 2. POST /auth/password/submit
        MockHTTPResponse->new(200, encode_json({ track_id => 'track_qr_001', csrf_token => 'csrf_abc_123' }), 1),
        # 3. POST /auth/magic/code
        MockHTTPResponse->new(200, encode_json({ link => 'https://passport.yandex.ru/am/push/qrsecure?track_id=track_qr_001&magic=magic_999' }), 1),
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::QRAuth->start_qr_login_sync();
    is($res->{track_id}, 'track_qr_001', 'start_qr_login_sync returns track_id');
    is($res->{qr_url}, 'https://passport.yandex.ru/am/push/qrsecure?track_id=track_qr_001&magic=magic_999', 'start_qr_login_sync returns dynamic QR url');
    is($res->{expires_in}, 300, 'expires_in defaults to 300');
    is($res->{interval}, 3, 'interval defaults to 3');

    is(scalar(@MockUA::calls), 3, 'Recorded 3 HTTP calls for start_qr_login_sync');
    is($MockUA::calls[0]->{method}, 'GET', 'Step 1 is GET');
    is($MockUA::calls[0]->{url}, 'https://passport.yandex.ru/pwl-yandex', 'Step 1 url is /pwl-yandex');
    is($MockUA::calls[1]->{method}, 'POST', 'Step 2 is POST');
    is($MockUA::calls[1]->{url}, 'https://passport.yandex.ru/pwl-yandex/api/passport/auth/password/submit', 'Step 2 is submit');
    is($MockUA::calls[2]->{method}, 'POST', 'Step 3 is POST');
    is($MockUA::calls[2]->{url}, 'https://passport.yandex.ru/pwl-yandex/api/passport/auth/magic/code', 'Step 3 is magic/code');
}

# Test poll_qr_token_sync (pending)
{
    # Session track_qr_001 is active in %ACTIVE_SESSIONS from previous step
    @MockUA::responses = (
        # Polling status returns empty object or non-finished state
        MockHTTPResponse->new(200, encode_json({}), 1),
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::QRAuth->poll_qr_token_sync('track_qr_001');
    is($res->{status}, 'pending', 'poll_qr_token_sync returns pending while empty response');
    is($MockUA::calls[0]->{url}, 'https://passport.yandex.ru/pwl-yandex/api/passport/auth/magic/code/status', 'Poll url is magic/code/status');
}

# Test poll_qr_token_sync (success & 7-step token exchange)
{
    # Seed session with cookies in jar
    my $session = $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'track_qr_001'};
    $session->{jar}->set_cookie(0, "Session_id", "session_id_val_999", "/", "passport.yandex.ru");
    $session->{jar}->set_cookie(0, "sessionid2", "sessionid2_val_999", "/", "passport.yandex.ru");

    @MockUA::responses = (
        # 1. status -> otp_auth_finished
        MockHTTPResponse->new(200, encode_json({ state => 'otp_auth_finished', trackId => 'session_track_777' }), 1),
        # 2. get_session
        MockHTTPResponse->new(200, encode_json({ status => 'ok' }), 1),
        # 3. token_by_sessionid -> x_token
        MockHTTPResponse->new(200, encode_json({ access_token => 'x_token_secret_123', token_type => 'bearer' }), 1),
        # 4. oauth.mobile.yandex.net/1/token -> music token
        MockHTTPResponse->new(200, encode_json({ access_token => 'music_token_final_999', expires_in => 31536000 }), 1),
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::QRAuth->poll_qr_token_sync('track_qr_001');
    is($res->{status}, 'ok', 'poll_qr_token_sync returns ok on otp_auth_finished');
    is($res->{access_token}, 'music_token_final_999', 'Music token extracted correctly');
    is($res->{x_token}, 'x_token_secret_123', 'x_token stored for session persistence');
    ok(!exists $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'track_qr_001'}, 'Active QR session cleared after success');

    is(scalar(@MockUA::calls), 4, '4 calls during confirmed poll');
    is($MockUA::calls[0]->{url}, 'https://passport.yandex.ru/pwl-yandex/api/passport/auth/magic/code/status', 'Step 4 is status');
    is($MockUA::calls[1]->{url}, 'https://passport.yandex.ru/pwl-yandex/api/passport/sessions/get_session', 'Step 5 is get_session');
    is($MockUA::calls[2]->{url}, 'https://mobileproxy.passport.yandex.net/1/bundle/oauth/token_by_sessionid', 'Step 6 is token_by_sessionid');
    is($MockUA::calls[3]->{url}, 'https://oauth.mobile.yandex.net/1/token', 'Step 7 is mobile token');
}

# Test poll_qr_token_sync (server error response)
{
    $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'track_qr_err'} = {
        track_id   => 'track_qr_err',
        csrf_token => 'csrf_token_test',
        auth_state => { track_id => 'track_qr_err', csrf_token => 'csrf_token_test' },
        jar        => HTTP::Cookies->new,
        created_at => time(),
        expires_in => 300,
    };

    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({ status => 'error', errors => ['csrf_token.invalid'] }), 1),
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::QRAuth->poll_qr_token_sync('track_qr_err');
    is($res->{status}, 'error', 'poll_qr_token_sync returns error when server returns error status');
    like($res->{message}, qr/csrf_token\.invalid/, 'Error message contains server diagnostic');
    ok(!exists $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'track_qr_err'}, 'Active QR session cleared on server error');
}

# Test cancel_qr_login
{
    $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'temp_cancel_track'} = { created_at => time() };
    ok(Plugins::yandex::API::QRAuth->cancel_qr_login('temp_cancel_track'), 'cancel_qr_login returns 1');
    ok(!exists $Plugins::yandex::API::QRAuth::ACTIVE_SESSIONS{'temp_cancel_track'}, 'Session removed on cancel');
}

# Test exchange_x_token_sync and refresh_access_token
{
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({ access_token => 'new_music_token_refreshed_555', expires_in => 31536000 }), 1),
    );
    @MockUA::calls = ();

    my $res = Plugins::yandex::API::QRAuth->exchange_x_token_sync('x_token_valid_123');
    is($res->{access_token}, 'new_music_token_refreshed_555', 'exchange_x_token_sync returns refreshed music token');
    is($MockUA::calls[0]->{url}, 'https://oauth.mobile.yandex.net/1/token', 'Target URL is music token endpoint');

    my $async_called = 0;
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({ access_token => 'new_async_token_777', expires_in => 31536000 }), 1),
    );
    Plugins::yandex::API::QRAuth->refresh_access_token(
        'x_token_valid_123',
        sub {
            my $r = shift;
            $async_called = 1;
            is($r->{access_token}, 'new_async_token_777', 'refresh_access_token async success');
        },
        sub { die "Should not fail"; }
    );
    is($async_called, 1, 'refresh_access_token invoked callback');
}

# =========================================================================
# 8. Settings Handler AJAX Endpoints for METHOD_QR
# =========================================================================

# Test Settings qr_action=start
{
    no warnings qw(redefine once);
    *Plugins::yandex::API::QRAuth::start_qr_login = sub {
        my ($class, $cb, $ecb, %args) = @_;
        $cb->({
            track_id   => 'track_settings_qr_1',
            qr_url     => 'https://passport.yandex.ru/am/push/qrsecure?track_id=1&magic=2',
            expires_in => 300,
            interval   => 3,
        });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { qr_action => 'start' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for qr_action=start');
    is($received_json->{success}, 1, 'qr_action=start response success is 1');
    is($received_json->{track_id}, 'track_settings_qr_1', 'track_id in response');
    is($received_json->{qr_url}, 'https://passport.yandex.ru/am/push/qrsecure?track_id=1&magic=2', 'qr_url in response');
    is($received_json->{interval}, 3, 'interval in response');
}

# Test Settings qr_action=poll (pending)
{
    no warnings 'redefine';
    *Plugins::yandex::API::QRAuth::poll_qr_token = sub {
        my ($class, $track_id, $cb, $ecb, %args) = @_;
        $cb->({ status => 'pending' });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { qr_action => 'poll', track_id => 'track_settings_qr_1' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for qr_action=poll pending');
    is($received_json->{status}, 'pending', 'Response status is pending');
}

# Test Settings qr_action=poll (success & account persistence)
{
    $Plugins::yandex::API::Async::mock_uid = 77889900;
    $Plugins::yandex::API::Async::mock_login = 'qr_user_test';
    $Plugins::yandex::API::Async::mock_name = 'QR Test User';

    no warnings 'redefine';
    *Plugins::yandex::API::QRAuth::poll_qr_token = sub {
        my ($class, $track_id, $cb, $ecb, %args) = @_;
        $cb->({
            status       => 'ok',
            access_token => 'music_token_from_qr_7788',
            x_token      => 'x_token_from_qr_7788',
            expires_in   => 31536000,
        });
    };
    use warnings 'redefine';

    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { qr_action => 'poll', track_id => 'track_settings_qr_1' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback for qr_action=poll success');
    is($received_json->{status}, 'ok', 'Response status is ok');
    is($received_json->{userId}, 77889900, 'Response contains userId');
    is($received_json->{login}, 'qr_user_test', 'Response contains login');

    # Verify stored account in preferences
    my $accounts = $prefs->get('accounts');
    ok(exists $accounts->{77889900}, 'Account stored in preferences by userId');
    is($accounts->{77889900}->{uid}, 77889900, 'uid saved in account');
    is($accounts->{77889900}->{token}, 'music_token_from_qr_7788', 'access_token saved in account');
    is($accounts->{77889900}->{x_token}, 'x_token_from_qr_7788', 'x_token saved in account');
    is($accounts->{77889900}->{auth_method}, 'qr', 'auth_method recorded as qr');
    is($accounts->{77889900}->{login}, 'qr_user_test', 'login saved in account');
    ok($Plugins::yandex::Plugin::initialized_clients{77889900}, 'Plugin::_init_api_client was called for the QR account');
}

# Test Settings qr_action=cancel
{
    my $callback_called = 0;
    my $received_json;

    my $callback = sub {
        my ($client, $params, $body_ref, @args) = @_;
        $callback_called = 1;
        $received_json = decode_json($$body_ref);
    };

    Plugins::yandex::Settings->handler(undef, { qr_action => 'cancel', track_id => 'track_settings_qr_1' }, $callback);
    is($callback_called, 1, 'Settings handler invoked callback on qr_action=cancel');
    is($received_json->{status}, 'cancelled', 'cancelled status returned for QR flow');
}

# Test silent refresh for QR account via x_token in Plugin.pm
{
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{'88990011'} = {
        token         => 'expired_qr_music_token_000',
        x_token       => 'valid_long_lived_xtoken_111',
        refresh_token => '',
        login         => 'qr_silent_user',
        name          => 'QR Silent User',
        uid           => '88990011',
        auth_method   => 'qr',
    };
    $prefs->set('accounts', $accounts);

    # Queue mock response for exchange_x_token
    @MockUA::responses = (
        MockHTTPResponse->new(200, encode_json({
            access_token => 'refreshed_qr_music_token_222',
            expires_in   => 31536000,
        }), 1),
    );

    my ($qr_refresh_success, $qr_refresh_error);
    Plugins::yandex::API::QRAuth->refresh_access_token(
        $accounts->{'88990011'}->{x_token},
        sub {
            my $res = shift;
            $qr_refresh_success = $res;
            my $accs = $prefs->get('accounts') || {};
            $accs->{'88990011'}->{token} = $res->{access_token};
            $prefs->set('accounts', $accs);
        },
        sub {
            $qr_refresh_error = shift;
        }
    );

    ok($qr_refresh_success, 'Silent refresh for QR account succeeded');
    is($qr_refresh_success->{access_token}, 'refreshed_qr_music_token_222', 'refreshed access_token returned for QR account');
    my $updated_accs = $prefs->get('accounts');
    is($updated_accs->{'88990011'}->{token}, 'refreshed_qr_music_token_222', 'Preferences updated with refreshed access_token via x_token');
}


