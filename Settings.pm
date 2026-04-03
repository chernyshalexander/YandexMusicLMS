package Plugins::yandex::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');
#$prefs->init({
#    token => '',
#    pref_fullName => '',
#    menuLocation => 'radio',
#    streamingQuality => 'highest',
#    descriptionInTitle => 0,
#    secondLineText => 'description',
#    translitSearch => 1
#});

sub name {
    return 'PLUGIN_YANDEX';
}

sub page {
    return 'plugins/yandex/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(menuLocation streamingQuality translitSearch max_bitrate remove_duplicates show_chart show_new_releases show_new_playlists show_audiobooks_in_collection search_podcasts enable_ynison show_wave_wizard wizard_station_type wizard_cat_diversity wizard_cat_mood wizard_cat_language));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{save_token}) {
		my $token = $params->{token};
		if ($token) {
			$prefs->set('token', $token);
			$log->info("Yandex Settings: Token captured via URL parameter.");

			# Validate in background
			require Plugins::yandex::API;
			my $yandex_client = Plugins::yandex::API->new($token);
			$yandex_client->init(
				sub {
					my $client_instance = shift;
					my $me = $client_instance->{me} || {};
					my $name = _format_full_name($me);
					$prefs->set('pref_fullName', $name || 'User');
					$log->info("Yandex Settings: Background validation successful for $name");
				},
				sub {
					$log->error("Yandex Settings: Background validation failed.");
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
		# Handle checkbox values - unchecked checkboxes don't appear in POST data (like Spotty-Plugin does)
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

		my $token = $params->{pref_token};
		my $oldToken = $prefs->get('token');
		my $placeholder = string('PLUGIN_YANDEX_TOKEN_SET') || '(Token is set)';

		$log->info("Yandex Settings: Save triggered. Token param: " . ($token || 'none') . ", enable_ynison: " . ($params->{pref_enable_ynison} || 0));

		# Handle placeholder case
		if ($token && ($token eq $placeholder || $token eq '(Token is set)')) {
			if ($prefs->get('pref_fullName') && $oldToken) {
				$log->info("Yandex Settings: Token unchanged (placeholder detected).");
				delete $params->{pref_token};
				$token = undef;
			} else {
				$log->info("Yandex Settings: Name missing, re-validating with existing token...");
				$token = $oldToken;
			}
		} 

		# If we have a token and (it's new OR name is missing), validate it
		if ($token && ($token ne ($oldToken || '') || !$prefs->get('pref_fullName'))) {
			$log->info("Yandex Settings: Validating token...");
			
			require Plugins::yandex::API;
			my $yandex_client = Plugins::yandex::API->new($token);
			
			$yandex_client->init(
				sub {
					my $client_instance = shift;
					my $me = $client_instance->{me} || {};
					my $name = _format_full_name($me);
					
					$prefs->set('token', $token);
					$prefs->set('pref_fullName', $name || 'User');
					$log->info("Yandex Settings: Login successful for " . $prefs->get('pref_fullName'));
					
					# Continue with standard handler
					$class->beforeRender($params);
					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
				sub {
					my $error = shift;
					$log->error("Yandex Settings: Login failed: $error");
					$params->{warning} = string('PLUGIN_YANDEX_AUTH_FAILED');
					
					# Re-render with warning
					$class->beforeRender($params);
					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				}
			);
			return; # Wait for async callback
		}
	}

	$class->beforeRender($params);
	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;
	$params->{pref_fullName} = $prefs->get('pref_fullName');
	if ($prefs->get('token')) {
		$params->{pref_tokenValue} = string('PLUGIN_YANDEX_TOKEN_SET') || '(Token is set)';
	} else {
		$params->{pref_tokenValue} = '';
	}

	$params->{enable_ynison} = $prefs->get('enable_ynison') // 0;
	
	my $deps = Plugins::yandex::API::check_dependencies();
	$params->{rijndael_missing} = !$deps->{rijndael};
	$params->{ffmpeg_missing}   = !$deps->{ffmpeg};

	$log->info("Yandex Settings: beforeRender. pref_fullName=" . ($params->{pref_fullName} || 'none') . " pref_tokenValue=" . $params->{pref_tokenValue});
}

sub _format_full_name {
	my $me = shift;
	
	my $login = $me->{login} || '';
	my $display = $me->{displayName} || '';
	my $second = $me->{secondName} || '';
	
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
