package Plugins::yandex::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');
#$prefs->init({ menuLocation => 'radio',  streamingQuality => 'highest', descriptionInTitle => 0, secondLineText => 'description',translitSearch =>1 });

# Returns the name of the plugin. The real 
# string is specified in the strings.txt file.
sub name {
    return 'PLUGIN_YANDEX';
}


sub page {
    return 'plugins/yandex/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(token menuLocation streamingQuality translitSearch max_bitrate));
}

# Always end with a 1 to make Perl happy
1;
