package Plugins::yandex::Settings;

=encoding utf8

=head1 NAME

Plugins::yandex::Settings - Web settings page for the Yandex Music plugin

=head1 DESCRIPTION

Handles GET/POST for the settings page (plugins/yandex/settings/basic.html).
Account management (add/delete) is done here asynchronously: token validation
requires a round-trip to the Yandex API before the page can be re-rendered,
so C<handler()> returns early and calls C<$callback> from within the API init
callback.

=cut

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Scalar::Util qw(blessed);
use Plugins::yandex::API::Common;

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

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

sub name {
    return 'PLUGIN_YANDEX';
}

sub page {
    return 'plugins/yandex/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(menuLocation translitSearch max_bitrate remove_duplicates show_chart show_new_releases show_new_playlists show_audiobooks_in_collection show_history show_resume_quick_item progress_save_interval search_podcasts search_waves enable_ynison ynison_debug show_wave_wizard wizard_station_type wizard_cat_diversity wizard_cat_mood wizard_cat_language vibe_wheel_rebuild_on_play aes_backend demux_backend));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	# Handle account deletion
	foreach my $key (keys %$params) {
		if ($key =~ /^delete_(.+)$/) {
			my $userId   = $1;
			my $accounts = $prefs->get('accounts') || {};
			if (exists $accounts->{$userId}) {
				delete $accounts->{$userId};
				$prefs->set('accounts', $accounts);
				Plugins::yandex::Plugin::_remove_api_client($userId);
				$log->info("Yandex Settings: Deleted account userId=$userId");
			}
		}
	}

	# -------------------------------------------------------------------------
	# OAuth Device Flow AJAX endpoints (Primary authentication method)
	# -------------------------------------------------------------------------
	if ($params->{device_action}) {
		my $action = $params->{device_action};

		# 1. Start Device Flow: request user_code & verification_url
		if ($action eq 'start') {
			$log->info("Yandex Settings: Starting OAuth Device Flow");
			require Plugins::yandex::API::DeviceAuth;

			Plugins::yandex::API::DeviceAuth->request_device_code(
				sub {
					my $res = shift;
					$log->info("Yandex Settings: Device code obtained: user_code=$res->{user_code}");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							success          => 1,
							user_code        => $res->{user_code},
							device_code      => $res->{device_code},
							verification_url => $res->{verification_url} || 'https://ya.ru/device',
							expires_in       => $res->{expires_in} || 300,
							interval         => $res->{interval} || 5,
						},
						@args
					);
				},
				sub {
					my $err = shift;
					$log->error("Yandex Settings: Failed to request device code: $err");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							success => 0,
							error   => "$err",
						},
						@args
					);
				}
			);
			return;
		}

		# 2. Poll Device Flow: check if user confirmed on ya.ru/device
		if ($action eq 'poll') {
			my $device_code = $params->{device_code};
			unless ($device_code) {
				return _send_json_response(
					$class, $client, $params, $callback,
					{
						status  => 'error',
						error   => 'missing_device_code',
						message => 'Missing device_code',
					},
					@args
				);
			}

			require Plugins::yandex::API::DeviceAuth;
			Plugins::yandex::API::DeviceAuth->poll_device_token(
				$device_code,
				sub {
					my $poll_res = shift;

					if ($poll_res->{status} eq 'pending') {
						_send_json_response(
							$class, $client, $params, $callback,
							{
								status => 'pending',
							},
							@args
						);
						return;
					}

					if ($poll_res->{status} eq 'ok') {
						my $token = $poll_res->{access_token};
						my $refreshToken = $poll_res->{refresh_token};

						$log->info("Yandex Settings: Device token received, validating account...");

						require Plugins::yandex::API::Async;
						my $yandex_client = Plugins::yandex::API::Async->new($token);
						$yandex_client->init(
							sub {
								my $client_instance = shift;
								my $me     = $client_instance->{me} || {};
								my $userId = $me->{uid};
								my $name   = _format_full_name($me);

								if ($userId) {
									my $accounts = $prefs->get('accounts') || {};
									$accounts->{$userId} = {
										token         => $token,
										refresh_token => $refreshToken || '',
										login         => $me->{login} || '',
										name          => $name || 'Account',
										uid           => $userId,
										auth_method   => 'device_code',
									};
									$prefs->set('accounts', $accounts);
									$log->info("Yandex Settings: Account added via Device Flow: userId=$userId ($name)");
									Plugins::yandex::Plugin::_remove_api_client($userId);
									Plugins::yandex::Plugin::_init_api_client($userId);

									_send_json_response(
										$class, $client, $params, $callback,
										{
											status => 'ok',
											userId => $userId,
											login  => $me->{login} || '',
											name   => $name,
										},
										@args
									);
								} else {
									$log->error("Yandex Settings: Device Flow validation failed: no uid in account status");
									_send_json_response(
										$class, $client, $params, $callback,
										{
											status  => 'error',
											message => 'Failed to obtain user ID from account status',
										},
										@args
									);
								}
							},
							sub {
								my $err = shift;
								$log->error("Yandex Settings: Device Flow token validation failed: $err");
								_send_json_response(
									$class, $client, $params, $callback,
									{
										status  => 'error',
										message => "Token validation failed: $err",
									},
									@args
								);
							}
						);
						return;
					}

					# Error from Yandex OAuth (e.g. expired_token, access_denied)
					$log->warn("Yandex Settings: Device Flow poll error: " . ($poll_res->{error} || ''));
					_send_json_response(
						$class, $client, $params, $callback,
						{
							status  => 'error',
							error   => $poll_res->{error} || 'unknown',
							message => $poll_res->{error_description} || $poll_res->{error} || 'Device authorization failed',
						},
						@args
					);
				},
				sub {
					my $err = shift;
					$log->error("Yandex Settings: Device Flow polling network error: $err");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							status  => 'error',
							message => "$err",
						},
						@args
					);
				}
			);
			return;
		}

		# 3. Cancel Device Flow
		if ($action eq 'cancel') {
			_send_json_response(
				$class, $client, $params, $callback,
				{
					status => 'cancelled',
				},
				@args
			);
			return;
		}
	}

	# -------------------------------------------------------------------------
	# Native Yandex Passport QR Flow AJAX endpoints (METHOD_QR)
	# -------------------------------------------------------------------------
	if ($params->{qr_action}) {
		my $action = $params->{qr_action};

		# 1. Start QR Flow: obtain dynamic magic QR link
		if ($action eq 'start') {
			$log->info("Yandex Settings: Starting native Yandex Passport QR login flow");
			require Plugins::yandex::API::QRAuth;

			Plugins::yandex::API::QRAuth->start_qr_login(
				sub {
					my $res = shift;
					$log->info("Yandex Settings: QR login session created, track_id=$res->{track_id}");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							success    => 1,
							track_id   => $res->{track_id},
							qr_url     => $res->{qr_url},
							expires_in => $res->{expires_in} || 300,
							interval   => $res->{interval} || 3,
						},
						@args
					);
				},
				sub {
					my $err = shift;
					$log->error("Yandex Settings: Failed to start QR login: $err");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							success => 0,
							error   => "$err",
						},
						@args
					);
				}
			);
			return;
		}

		# 2. Poll QR Flow: check if user confirmed via Yandex App
		if ($action eq 'poll') {
			my $track_id = $params->{track_id};
			unless ($track_id) {
				return _send_json_response(
					$class, $client, $params, $callback,
					{
						status  => 'error',
						error   => 'missing_track_id',
						message => 'Missing track_id',
					},
					@args
				);
			}

			require Plugins::yandex::API::QRAuth;
			Plugins::yandex::API::QRAuth->poll_qr_token(
				$track_id,
				sub {
					my $poll_res = shift;

					if ($poll_res->{status} eq 'pending') {
						_send_json_response(
							$class, $client, $params, $callback,
							{
								status => 'pending',
							},
							@args
						);
						return;
					}

					if ($poll_res->{status} eq 'ok') {
						my $token   = $poll_res->{access_token};
						my $x_token = $poll_res->{x_token};

						$log->info("Yandex Settings: QR login confirmed, validating account...");

						require Plugins::yandex::API::Async;
						my $yandex_client = Plugins::yandex::API::Async->new($token);
						$yandex_client->init(
							sub {
								my $client_instance = shift;
								my $me     = $client_instance->{me} || {};
								my $userId = $me->{uid};
								my $name   = _format_full_name($me);

								if ($userId) {
									my $accounts = $prefs->get('accounts') || {};
									$accounts->{$userId} = {
										token         => $token,
										x_token       => $x_token || '',
										refresh_token => '',
										login         => $me->{login} || '',
										name          => $name || 'Account',
										uid           => $userId,
										auth_method   => 'qr',
									};
									$prefs->set('accounts', $accounts);
									$log->info("Yandex Settings: Account added via QR Flow: userId=$userId ($name)");
									Plugins::yandex::Plugin::_remove_api_client($userId);
									Plugins::yandex::Plugin::_init_api_client($userId);

									_send_json_response(
										$class, $client, $params, $callback,
										{
											status => 'ok',
											userId => $userId,
											login  => $me->{login} || '',
											name   => $name,
										},
										@args
									);
								} else {
									$log->error("Yandex Settings: QR Flow validation failed: no uid in account status");
									_send_json_response(
										$class, $client, $params, $callback,
										{
											status  => 'error',
											message => 'Failed to obtain user ID from account status',
										},
										@args
									);
								}
							},
							sub {
								my $err = shift;
								$log->error("Yandex Settings: QR Flow token validation failed: $err");
								_send_json_response(
									$class, $client, $params, $callback,
									{
										status  => 'error',
										message => "Token validation failed: $err",
									},
									@args
								);
							}
						);
						return;
					}

					$log->warn("Yandex Settings: QR Flow poll error: " . ($poll_res->{error} || ''));
					_send_json_response(
						$class, $client, $params, $callback,
						{
							status  => 'error',
							error   => $poll_res->{error} || 'unknown',
							message => $poll_res->{message} || $poll_res->{error} || 'QR authorization failed',
						},
						@args
					);
				},
				sub {
					my $err = shift;
					$log->error("Yandex Settings: QR Flow polling network error: $err");
					_send_json_response(
						$class, $client, $params, $callback,
						{
							status  => 'error',
							message => "$err",
						},
						@args
					);
				}
			);
			return;
		}

		# 3. Cancel QR Flow
		if ($action eq 'cancel') {
			my $track_id = $params->{track_id};
			if ($track_id) {
				require Plugins::yandex::API::QRAuth;
				Plugins::yandex::API::QRAuth->cancel_qr_login($track_id);
			}
			_send_json_response(
				$class, $client, $params, $callback,
				{
					status => 'cancelled',
				},
				@args
			);
			return;
		}
	}

	# OAuth callback — token arrives via URL parameter (bookmarklet/drag-drop)
	if ($params->{save_token}) {
		my $token = $params->{token};
		if ($token) {
			$log->info("Yandex Settings: Token received via OAuth callback, validating...");

			require Plugins::yandex::API::Async;
			my $yandex_client = Plugins::yandex::API::Async->new($token);
			$yandex_client->init(
				sub {
					my $client_instance = shift;
					my $me   = $client_instance->{me} || {};
					my $userId = $me->{uid};
					my $name   = _format_full_name($me);

					if ($userId) {
						my $accounts = $prefs->get('accounts') || {};
						$accounts->{$userId} = {
							token => $token,
							login => $me->{login} || '',
							name  => $name || 'Account',
							uid   => $userId,
						};
						$prefs->set('accounts', $accounts);
						$log->info("Yandex Settings: Account added/updated: userId=$userId name=$name");
						# Re-initialize API client for this account
						Plugins::yandex::Plugin::_remove_api_client($userId);
						Plugins::yandex::Plugin::_init_api_client($userId);
					}
				},
				sub {
					$log->error("Yandex Settings: OAuth token validation failed.");
				}
			);

			my $body = "<html><body style='font-family:sans-serif;text-align:center;padding-top:50px;'>
				<h2>Authorization successful!</h2>
				<p>The token has been saved. You can close this window and refresh the settings page.</p>
				<script>setTimeout(function(){ window.close(); }, 3000);</script>
			</body></html>";
			return \$body;
		}
	}

	if ($params->{saveSettings}) {
		# Handle checkbox values
		$params->{pref_remove_duplicates}              ||= 0;
		$params->{pref_show_chart}                     ||= 0;
		$params->{pref_show_new_releases}              ||= 0;
		$params->{pref_show_new_playlists}             ||= 0;
		$params->{pref_show_audiobooks_in_collection}  ||= 0;
		$params->{pref_search_podcasts}                ||= 0;
		$params->{pref_search_waves}                   ||= 0;
		$params->{pref_enable_ynison}                  ||= 0;
		$params->{pref_ynison_debug}                   ||= 0;
		$params->{pref_show_wave_wizard}               ||= 0;
		$params->{pref_wizard_station_type}            //= 'activity';
		$params->{pref_wizard_cat_diversity}           ||= 0;
		$params->{pref_wizard_cat_mood}                ||= 0;
		$params->{pref_wizard_cat_language}            ||= 0;
		$params->{pref_vibe_wheel_rebuild_on_play}     ||= 0;
		$params->{pref_show_history}                   ||= 0;
		$params->{pref_show_resume_quick_item}         ||= 0;
		$params->{pref_progress_save_interval}         = int($params->{pref_progress_save_interval} || 30);
		if (exists $params->{pref_max_bitrate}) {
			$params->{pref_max_bitrate} = Plugins::yandex::API::Common::normalize_quality($params->{pref_max_bitrate});
		}

		# Handle adding a new account via token field
		my $newToken = $params->{new_account_token};
		if ($newToken && $newToken !~ /^\s*$/) {
			$log->info("Yandex Settings: Adding new account, validating token...");

			require Plugins::yandex::API::Async;
			my $yandex_client = Plugins::yandex::API::Async->new($newToken);

			$yandex_client->init(
				sub {
					my $client_instance = shift;
					my $me     = $client_instance->{me} || {};
					my $userId = $me->{uid};
					my $name   = _format_full_name($me);

					if ($userId) {
						my $accounts = $prefs->get('accounts') || {};
						$accounts->{$userId} = {
							token => $newToken,
							login => $me->{login} || '',
							name  => $name || 'Account',
							uid   => $userId,
						};
						$prefs->set('accounts', $accounts);
						$log->info("Yandex Settings: Account added: userId=$userId ($name)");
						Plugins::yandex::Plugin::_remove_api_client($userId);
						Plugins::yandex::Plugin::_init_api_client($userId);
					}

					$class->beforeRender($params);
					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
				sub {
					my $error = shift;
					$log->error("Yandex Settings: Token validation failed: $error");
					$params->{warning} = string('PLUGIN_YANDEX_AUTH_FAILED');
					$class->beforeRender($params);
					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				}
			);
			return;  # Wait for async callback
		}
	}

	$class->beforeRender($params);
	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	# Build accounts list for template
	my $accounts = $prefs->get('accounts') || {};
	my @accounts_list;
	foreach my $userId (sort keys %$accounts) {
		next if $userId eq 'migrating';
		my $acc = $accounts->{$userId};
		push @accounts_list, {
			userId => $userId,
			name   => $acc->{name} || $acc->{login} || $userId,
			login  => $acc->{login} || '',
		};
	}
	$params->{accounts} = \@accounts_list;

	my $deps = Plugins::yandex::API::Async::check_dependencies();
	$params->{rijndael_available} = $deps->{rijndael};
	$params->{rijndael_missing}   = !$deps->{rijndael};
	$params->{ffmpeg_available}   = $deps->{ffmpeg};
	$params->{ffmpeg_missing}     = !$deps->{ffmpeg};

	$log->info("Yandex Settings: beforeRender. accounts=" . scalar(@accounts_list));
}

sub _format_full_name {
	my $me = shift;

	my $login   = $me->{login}       || '';
	my $display = $me->{displayName} || '';
	my $second  = $me->{secondName}  || '';

	my $name = $login;
	if ($display || $second) {
		my $full = $display;
		if ($second && (!$display || index($display, $second) == -1)) {
			$full .= ($full ? ' ' : '') . $second;
		}
		$name .= ($name ? ' ' : '') . "($full)";
	}

	return $name || $me->{fullName} || $me->{name} || 'Account';
}

sub _send_json_response {
	my ($class, $client, $params, $callback, $data, @args) = @_;

	my $json_str;
	if (defined &encode_json) {
		$json_str = eval { encode_json($data) };
	}
	if (!defined $json_str && eval { require JSON::PP; 1 }) {
		$json_str = eval { JSON::PP::encode_json($data) };
	}
	if (!defined $json_str) {
		$json_str = '{"status":"error","message":"JSON encode error"}';
	}

	# In Slim::Web::HTTP, $args[1] is the HTTP::Response object
	if ($args[1] && blessed($args[1]) && $args[1]->can('content_type')) {
		$args[1]->content_type('application/json; charset=utf-8');
	}

	if ($callback) {
		$callback->($client, $params, \$json_str, @args);
		return;
	}
	return \$json_str;
}

1;
