package Plugins::yandex::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

sub name {
    return 'PLUGIN_YANDEX';
}

sub page {
    return 'plugins/yandex/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(menuLocation streamingQuality translitSearch max_bitrate remove_duplicates show_chart show_new_releases show_new_playlists show_audiobooks_in_collection search_podcasts enable_ynison show_wave_wizard wizard_station_type wizard_cat_diversity wizard_cat_mood wizard_cat_language aes_backend demux_backend));
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

	# OAuth callback — token arrives via URL parameter (bookmarklet/drag-drop)
	if ($params->{save_token}) {
		my $token = $params->{token};
		if ($token) {
			$log->info("Yandex Settings: Token received via OAuth callback, validating...");

			require Plugins::yandex::API;
			my $yandex_client = Plugins::yandex::API->new($token);
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
						};
						$prefs->set('accounts', $accounts);
						$log->info("Yandex Settings: Account added/updated: userId=$userId name=$name");
						# Initialize API client for this account
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
		$params->{pref_enable_ynison}                  ||= 0;
		$params->{pref_show_wave_wizard}               ||= 0;
		$params->{pref_wizard_station_type}            //= 'activity';
		$params->{pref_wizard_cat_diversity}           ||= 0;
		$params->{pref_wizard_cat_mood}                ||= 0;
		$params->{pref_wizard_cat_language}            ||= 0;

		# Handle adding a new account via token field
		my $newToken = $params->{new_account_token};
		if ($newToken && $newToken !~ /^\s*$/) {
			$log->info("Yandex Settings: Adding new account, validating token...");

			require Plugins::yandex::API;
			my $yandex_client = Plugins::yandex::API->new($newToken);

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
						};
						$prefs->set('accounts', $accounts);
						$log->info("Yandex Settings: Account added: userId=$userId ($name)");
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

	my $deps = Plugins::yandex::API::check_dependencies();
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
		$name .= " ($full)";
	}

	return $name;
}

1;
