use Thread;

sub foo {
    my $arg = shift;
    my $t = Thread->self;
    print "foo: self = $t (dereferencing for tid = $$t)\n";
    printf "foo: self->tid = %d, arg = %s\n", $t->tid, $arg;
}

for (my $i = 0; $i < 5; $i++) {
    my $foo = Thread->new(\&foo, $i + 10);
    print "main thread: foo = $foo (dereferencing for tid = $$foo)\n";
    print "main thread: foo->tid = ", $foo->tid, "\n";
}
