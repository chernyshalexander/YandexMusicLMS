for my $m ('<?xm', '<Err', '<!DO', '<htm', 'fLaC', 'ftyp') {
    if ($m =~ /^(?:<\?xm|<err|<!do|<htm)/i) {
        print "$m matches\n";
    } else {
        print "$m NO\n";
    }
}
