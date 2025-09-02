package Plugins::yandex::Request;

use strict;
use warnings;
use LWP::UserAgent;
use URI;
use HTTP::Request;
use JSON;

sub new {
    my ($class, %args) = @_;
    my $self = {
        ua => LWP::UserAgent->new,
        token => $args{token},
        proxy_url => $args{proxy_url},
    };

    # Установка заголовков
    $self->{ua}->default_header('User-Agent' => 'Yandex-Music-API');
    $self->{ua}->default_header('X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621');
    $self->{ua}->default_header('Accept-Language' => 'ru');
    if ($self->{proxy_url}) {
        warn "SOCKS5 не поддерживается в Perl напрямую. Используйте HTTP.";
        $self->{ua}->proxy(['http', 'https'], $self->{proxy_url});
    }

    bless $self, $class;
    return $self;
}

sub get {
    my ($self, $url, $params) = @_;

    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $req = HTTP::Request->new(GET => $uri);
    $req->header('Authorization' => "OAuth " . $self->{token}) if $self->{token};
   
    my $res = $self->{ua}->request($req);

    #Логируем заголовки 
    # print "[DEBUG] Отправка GET-запроса на $uri\n";
    # print "[DEBUG] Заголовки:\n";
    # foreach my $header ($req->headers->header_field_names()) {
    #    print " - $header: " . $req->header($header) . "\n";
    # }

    unless ($res->is_success) {
        die "HTTP error: " . $res->status_line;
    }
    #print $res->decoded_content;
    return decode_json($res->decoded_content);
}

sub post {
    my ($self, $url, $data) = @_;

    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->header('Authorization' => "OAuth " . $self->{token}) if $self->{token};
    $req->content(encode_json($data));

    my $res = $self->{ua}->request($req);

    unless ($res->is_success) {
        die "HTTP error: " . $res->status_line;
    }

    return decode_json($res->decoded_content);
}

1;