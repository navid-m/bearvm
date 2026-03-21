my $n = 1000000;

my @arr = (0,0) xx $n;

for ^$n -> $i {
    @arr[$i] = ($i, $i × 2);
}

for ^$n -> $i {
    my ($x, $y)   = @arr[$i];
    @arr[$i] = ($x + $y, $y);
}

my $sum = @arr.map({ $^a[0] + $^a[1] }).sum;

say $sum;
