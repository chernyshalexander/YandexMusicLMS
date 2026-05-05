use strict;
use warnings;
use JSON::PP;
use Data::Dumper;

my $token = `grep -oP '"token":"\\K[^"]+' /home/chernysh/.squeezebox/prefs/plugin/yandex.prefs 2>/dev/null` || "";
chomp $token;

sub test_search {
    my ($query, $type) = @_;
    my $cmd = "curl -s -H 'Authorization: OAuth $token' 'https://api.music.yandex.net/search?text=$query&type=$type&page=0&page-size=50'";
    my $json = `$cmd`;
    my $data = decode_json($json);
    return $data->{result};
}

my $query = "deep%20purple";
print "--- Testing type=all ---\n";
my $all = test_search($query, "all");
foreach my $cat (qw(artists albums tracks)) {
    if ($all->{$cat}) {
        my $total = $all->{$cat}->{total};
        my $returned = scalar @{$all->{$cat}->{results} || []};
        print "$cat: total=$total, returned=$returned\n";
    }
}

print "\n--- Testing type=album ---\n";
my $albums = test_search($query, "album");
if ($albums->{albums}) {
    my $total = $albums->{albums}->{total};
    my $returned = scalar @{$albums->{albums}->{results} || []};
    print "albums: total=$total, returned=$returned\n";
}
