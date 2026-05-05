use strict;
use warnings;
use JSON::PP;
use Data::Dumper;

my $req = {
    id => 1,
    method => "slim.request",
    params => ["", ["search", "0", "10", "term:deep purple"]]
};

my $json_req = encode_json($req);
my $res = `curl -s -X POST -H "Content-Type: application/json" -d '$json_req' http://localhost:9000/jsonrpc.js`;
my $data = decode_json($res);

my $items = $data->{result}->{item_loop};
my $yandex_found = 0;

foreach my $item (@$items) {
    print "Found item: " . ($item->{name} || '') . "\n";
    if ($item->{item_loop}) {
        foreach my $sub_item (@{$item->{item_loop}}) {
            if ($sub_item->{name} =~ /yandex/i || $item->{name} =~ /yandex/i) {
                $yandex_found = 1;
                print "  -> Yandex item: " . ($sub_item->{name} || '') . "\n";
            }
        }
    }
}
print "Yandex search results were " . ($yandex_found ? "found!" : "NOT found!") . "\n";
