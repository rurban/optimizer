package optimizer;
use Carp;
use B;
{ no warnings 'redefine';
use B::Generate;
}
use 5.007002;
use strict;
use warnings;

require DynaLoader;
our $VERSION = '0.06_01';
our @ISA=q(DynaLoader);
our %callbacks;
bootstrap optimizer $VERSION;

my ($file, $line) = ("unknown", "unknown");

{
sub preparewarn { 
    my $args = join '', @_;
    $args = "Something's wrong " unless $args;
    $args .= " at $file line $line.\n" unless substr($args, length($args) -1) eq "\n";
}

sub update {
    my $cop = shift; $file = $cop->file; $line = $cop->line;
}

sub die (@) { CORE::die(preparewarn(@_)) }
sub warn (@) { CORE::warn(preparewarn(@_)) }
}

sub import {
    my ($class,$type) = (shift, shift);
    if (!defined $type) {
        CORE::warn("Must pass an action to ${class}'s importer");
        return
    }
    if ($type eq 'C' or $type eq 'c') {
        optimizer::uninstall();
    } elsif ($type =~ /^Perl$/i) {
        optimizer::install( sub { optimizer::peepextend($_[0], sub {}) });
    } elsif ($type eq "callback" or $type eq "extend" or $type eq "mine") {
        my $subref = shift;
        croak "Supplied callback was not a subref" unless ref $subref eq "CODE";
        optimizer::install( sub { callbackoptimizer($_[0],$subref) }) if $type eq "callback";
        optimizer::install( sub { optimizer::peepextend($_[0], $subref) }) if $type eq "extend";
        optimizer::install( $subref ) if $type eq "mine";
    } elsif ($type eq 'extend-c') {

      optimizer::c_extend_install(shift);
    } elsif ($type eq 'sub-detect') {
      my ($package, $filename, $line) = caller;
      $callbacks{$package} = shift;
      optimizer::c_sub_detect_install();
    } else { croak "Unknown optimizer option '$type'"; }
}

sub unimport {
    optimizer::install(sub {callbackoptimizer($_[0], sub{})});
}

sub callbackoptimizer {
    my ($op, $callback) = @_;
    while ($$op) {
        $op->seq(optimizer::op_seqmax_inc());
        update($op) if $op->isa("B::COP");
        relocatetopad($op, $op->find_cv()) if $op->name eq "const"; # For thread safety

        $callback->($op);
        $op = $op->next;
        last unless $op->can("next"); # Shouldn't get here
    }
}

sub peepextend {
    # Oh boy
    my ($o, $callback) = @_;
    my $oldop = 0;

    return if !$$o or $o->seq;

    op_seqmax_inc() unless op_seqmax();
    while ($$o) {
        #warn ("Trying op $o ($$o) -> ".$o->name."\n");
        if ($o->isa("B::COP")) {

            $o->seq(optimizer::op_seqmax_inc());
            update($o); # For warnings

        } elsif ($o->name eq "const") {
            optimizer::die("Bareword ",$o->sv->sv, " not allowed while \"strict subs\" in use")
                if ($o->private & 8);

            relocatetopad($o,$o->find_cv());
            $o->seq(optimizer::op_seqmax_inc());
        } elsif ($o->name eq "concat") {
            if ($o->next && $o->next->name eq "stringify" and !($o->flags &64)) {
                if ($o->next->private & 16) {
                    $o->targ($o->next->targ);
                    $o->next->targ(0);
                }
                #$o->null;
            }
            $o->seq(optimizer::op_seqmax_inc());
        #} elsif ($o->name eq "stub") {
        #    CORE::die "Eep.";
        #} elsif ($o->name eq "null") {
        #   CORE::die "Eep.";
        } elsif ($o->name eq "scalar" or $o->name eq "lineseq" or $o->name eq "scope") {
            if ($$oldop and ${$o->next}) {
                $oldop->next($o->next);
                $o=$o->next;
                next;
            }
            $o->seq(optimizer::op_seqmax_inc());
        #} elsif ($o->name eq "gv") { 
        #    CORE::die "Eep.";
        } elsif ($o->name =~ /^((map|grep)while|(and|or)(assign)?|cond_expr|range)$/) {
            $o->seq(optimizer::op_seqmax_inc());
            $o->other($o->other->next) while $o->other->name eq "null";
            peepextend($o->other, $callback); # Weee.
        } elsif ($o->name =~ /^enter(loop|iter)/) {
            $o->seq(optimizer::op_seqmax_inc());
            $o->redoop($o->redoop->next) while $o->redoop->name eq "null"; peepextend($o->redoop, $callback);
            $o->nextop($o->nextop->next) while $o->nextop->name eq "null"; peepextend($o->nextop, $callback);
            $o->lastop($o->lastop->next) while $o->lastop->name eq "null"; peepextend($o->lastop, $callback);
        } elsif ($o->name eq "qr" or $o->name eq "match" or $o->name eq "subst") {
            $o->seq(optimizer::op_seqmax_inc());
            $o->pmreplstart($o->pmreplstart->next) while ${$o->pmreplstart} and $o->pmreplstart->name eq "null"; 
            peepextend($o->pmreplstart, $callback);
        } elsif ($o->name eq "exec") {
            $o->seq(optimizer::op_seqmax_inc());
            if (${$o->next} and $o->next->name eq "nextstate" and
                ${$o->next->sibling} and $o->next->sibling->type !~ /exit|warn|die/) {
                optimizer::warn("Statement unlikely to be reached");
                optimizer::warn("\t(Maybe you meant system() when you said exec()?)\n");
            }
        } else {
            # Screw pseudohashes.
            $o->seq(optimizer::op_seqmax_inc());
        }
        my $plop = $o;

        $callback->($o);
        $oldop = $o;
        $o = $o->next;
        last unless $o->can("next"); # Shouldn't get here
    }
}    

1;
__END__
# Below is stub documentation for your module. You better edit it!

=head1 NAME

optimizer - Write your own Perl optimizer, in Perl

=head1 SYNOPSIS

  # Use Perl's default optimizer
  use optimizer 'C'; 

  # Use a Perl implementation of the default optimizer
  use optimizer 'perl'; 

  # Use an extension of the default optimizer
  use optimizer extend => sub {
        warn "goto considered harmful" if $_[0]-1>name eq "goto"
  }

  # Use a simple optimizer with callbacks for each op
  use optimizer callback => sub { .. }

  # Completely implement your own optimizre
  use optimizer mine => sub { ... }

  # use the standard optimizer with an extra callback
  # this is the most compatible optimizer version
  use optimizer extend-c => sub { print $_[0]->name() };

  # don't provide a peep optimizer, rather get a callback
  # after we are finished with every code block
  use optimizer sub-detect => sub { print $_[0]->name() };

  no optimizer; # Use the simplest working optimizer

=head1 DESCRIPTION

This module allows you to replace the default Perl optree
optimizer, C<peep>, with a Perl function of your own devising.

It requires a Perl patched with the patch supplied with the 
module distribution; this patch allows the optimizer to be
pluggable and replaceable with a C function pointer. This module
provides the glue between the C function and a Perl subroutine. It 
is hoped that the patch will be integrated into the Perl core at 
some point soon. This patch is integrated as of perl 5.8.

Your optimizer subroutine will be handed a C<B::OP>-derived object
representing the first (NOT the root) op in the program. You are
expected to be fluent with the C<B> module to know what to do with this.
You can use C<B::Generate> to fiddle around with the optree you are
given, while traversing it in execution order. 

If you choose complete control over your optimizer, you B<must> assign
sequence numbers to operations. This can be done via the
C<optimizer::op_seqmax_inc> function, which supplies a new
incremented sequence number. Do something like this:

    while ($$op) {
        $op->seq(optimizer::op_seqmax_inc);

        ... more optimizations ...

        $op = $op->next; 
        last unless $op->can("next"); # Shouldn't get here
    }

The C<callback> option to this module will essentially do the above,
calling your given subroutine with each op. 

If you just want to use this function to get a callback after every
code block is compiled so you can do any arbitrary work on it use the
C<sub-detect> option, you will be passed LEAVE* ops after the standard
peep optimizer has been run, this minimises the risk for bugs as we 
use the standard one. The op tree you are handed is also stable so you
are free to work on it. This is usefull if you are limited by 
C<CHECK> and C<INIT> blocks as this works with string eval and
C<require> aswell. Only one callback per package is allowed.

=head1 AUTHOR

Simon Cozens, C<simon@cpan.org>

Extended functionality and current maintainer.

Arthur Bergman, C<abergman@cpan.org>

=head1 SEE ALSO

L<B::Generate>, L<optimize>

=cut
