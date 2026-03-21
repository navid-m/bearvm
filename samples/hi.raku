my $n = 10;   # or whatever value

my @arr = (0,0) xx $n;          # no need for [ ] here

# fill
for ^$n -> $i {
    @arr[$i] = ($i, $i × 2);
}

# transform
for ^$n -> $i {
    my ($x, $y)   = @arr[$i];
    @arr[$i] = ($x + $y, $y);
}

# sum (can be written shorter)
my $sum = @arr.map({ $^a[0] + $^a[1] }).sum;

say $sum;
