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
use Digest::MD5 qw(md5_hex);
use Data::Dumper;

# === НАСТРОЙКИ ===
<<<<<<< HEAD

=======
#my тут должен быть токен
>>>>>>> 52f1982 (+ProtocolHandler)
my $TRACK_ID = '47742192'; # ID трека из вашего debug-tracks.json (Partyfine)
# =================

print "=== START DEBUG ===\n";

# 1. Инициализация
my $client = Plugins::yandex::Client->new($TOKEN);
# Создаем "фейковый" request объект, если он не создался внутри Client
unless ($client->{request}) {
    $client->{request} = Plugins::yandex::Request->new(token => $TOKEN);
}

print "1. Client created.\n";

# 2. Создаем объект трека
my $track = Plugins::yandex::Track->new({ id => $TRACK_ID });
print "2. Track object created for ID: $TRACK_ID\n";

# 3. Получаем Download Info (список вариантов загрузки)
print "3. Requesting download info...\n";
$track->get_download_info($client);

unless ($track->{download_info} && $track->{download_info}->{result}) {
    die "ERROR: No download info received. Check Token or Track ID.\nResponse: " . Dumper($track->{download_info});
}
print "   Download info received (" . scalar(@{$track->{download_info}->{result}}) . " variants).\n";

# 4. Ищем MP3
my $target_info;
foreach my $info (@{$track->{download_info}->{result}}) {
    if ($info->{codec} eq 'mp3') {
        $target_info = $info;
        # Берем 320 или 192, что есть
        last if $info->{bitrateInKbps} == 320;
    }
}

unless ($target_info) {
    die "ERROR: No MP3 codec found in response.\n";
}

my $dw_url = $target_info->{downloadInfoUrl};
print "4. Found download URL: $dw_url\n";

# 5. Запрашиваем XML/JSON с данными для хеша
print "5. Fetching XML/JSON data...\n";
my $res_xml = $client->{request}->{ua}->get($dw_url);

unless ($res_xml->is_success) {
    die "ERROR: Failed to fetch XML: " . $res_xml->status_line . "\n";
}

my $content = $res_xml->decoded_content;
print "   Raw content: $content\n";

# 6. Парсинг (Regex)
my ($host) = $content =~ /<host>(.*?)<\/host>/;
my ($path) = $content =~ /<path>(.*?)<\/path>/;
my ($ts)   = $content =~ /<ts>(.*?)<\/ts>/;
my ($s)    = $content =~ /<s>(.*?)<\/s>/;

# Если XML не сработал, пробуем JSON (иногда Яндекс меняет формат)
unless ($host) {
    print "   Regex failed for XML, trying simplified JSON parsing...\n";
    if ($content =~ /"host":"(.*?)".*"path":"(.*?)".*"ts":"(.*?)".*"s":"(.*?)"/) {
        $host = $1; $path = $2; $ts = $3; $s = $4;
    }
}

if ($host && $path && $ts && $s) {
    print "6. Parsed Data:\n   Host: $host\n   Path: $path\n   Ts: $ts\n   S: $s\n";
    
    # 7. Генерация подписи
    my $SALT = 'XGRlBW9FXlekgbPrRHuSiA';
    # ВАЖНО: substr($path, 1) убирает первый слеш, если он есть. 
    # Обычно path начинается с /, например /get-mp3/...
    # Хеш считается от: SALT + path_without_leading_slash + s
    
    my $path_for_hash = $path;
    if (substr($path_for_hash, 0, 1) eq '/') {
        $path_for_hash = substr($path_for_hash, 1);
    }
    
    my $sign_string = $SALT . $path_for_hash . $s;
    my $sign = md5_hex($sign_string);
    
    print "7. Sign string (salt+path+s): $sign_string\n";
    print "   MD5 Hash: $sign\n";
    
    my $final_url = "https://$host/get-mp3/$sign/$ts$path";
    print "\n=== RESULT URL ===\n$final_url\n";
    print "Try opening this URL in browser or VLC player.\n";
    
} else {
    die "ERROR: Could not parse Host/Path/Ts/S from response.\n";
}