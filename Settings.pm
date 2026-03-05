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
    return ($prefs, qw(menuLocation streamingQuality translitSearch max_bitrate use_new_radio_api remove_duplicates));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		my $token = $params->{pref_token};
		my $oldToken = $prefs->get('token');
		my $placeholder = string('PLUGIN_YANDEX_TOKEN_SET') || '(Token is set)';

		$log->info("Yandex Settings: Save triggered. Token param: " . ($token || 'none'));

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
			
			require Plugins::yandex::ClientAsync;
			my $yandex_client = Plugins::yandex::ClientAsync->new($token);
			
			$yandex_client->init(
				sub {
					my $client_instance = shift;
					my $me = $client_instance->{me} || {};
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
	$log->info("Yandex Settings: beforeRender. pref_fullName=" . ($params->{pref_fullName} || 'none') . " pref_tokenValue=" . $params->{pref_tokenValue});
}

1;
