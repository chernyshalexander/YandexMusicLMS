use strict;
use warnings;
use FindBin;
use Encode;
use lib "$FindBin::Bin/../";
use Client;
use Request;
use Track;
use TrackShort;
use open ':std', ':encoding(UTF-8)';


#Установка кодировки консоли под Windows
if ($^O eq 'MSWin32') {
    require Win32::Console;
    Win32::Console::OutputCP(65001);
}
my $token = '';


my $client = YandexMusicLMS::Client->new($token)->init();

my $user = $client->get_me();
print "Hello, " . ($user->{login} // 'неизвестный') . "\n";
print "Full Name: " . ($user->{fullName} // 'не указано') . "\n";
print "Display Name: " . ($user->{displayName} // 'не указано') . "\n";

#print decode_utf8("Ваши понравившиеся треки:\n");
my $liked_tracks = $client->users_likes_tracks();
foreach my $track_short (@$liked_tracks) {
    my $full_track = $track_short->fetch_track($client);
    my $title = $full_track->{title};
    # 
    my $artists = join ', ', 
    map { $_->{name} } @{$full_track->{artists}};
    # print " - $artists - $title\n";

#     # Раскомментируй, чтобы скачать первый трек
    #$full_track->download($client, "$track_short->{track_id}.mp3");
    $full_track->get_download_info($client);
 }
1;