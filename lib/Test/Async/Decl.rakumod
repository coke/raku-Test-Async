use v6;

=begin pod
=NAME 

C<Test::Async::Decl> - declarations for writing new bundles

=SYNOPSIS

    use Test::Async::Decl;

    unit test-bundle MyBundle;

    method my-tool(...) is test-tool(:name<mytool>, :!skippable, :!readify) {
        ...
    }

=DESCRIPTION

This module exports declarations needed to write custom bundles for C<Test::Async> framework.

=head2 C<test-bundle>

Declares a bundle role backed by
L<C<Test::Async::Metamodel::BundleHOW>|https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Metamodel/BundleHOW.md>
metaclass.

=head2 C<test-reporter>

Declares a bundle role wishing to act as a reporter. Backed by
L<C<Test::Async::Metamodel::ReporterHOW>|https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Metamodel/ReporterHOW.md>
metaclass. The bundle also consumes
L<C<Test::Async::Reporter>|https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Reporter.md>
role.

=head2 C<test-hub>

This kind of package creates a hub class which is backed by
L<C<Test::Async::Metamodel::HubHOW>|https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Metamodel/HubHOW.md>
metaclass. Barely useful for a third-party developer.

=head2 C<&trait_mod:<is>(Method:D \meth, :$test-tool!)>

This trait is used to declare a method in a bundle as a test tool:

    method foo(...) is test-tool {
        ...
    }

The method is then exported to user as C<&foo> routine. Internally the method is getting wrapped into a code which
does necessary preparations for the tool to act as expected. See
L<C<Test::Async::Metamodel::BundleClassHOW>|https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Metamodel/BundleClassHOW.md> 
for more details.

=AUTHOR Vadim Belman <vrurg@cpan.org>

=end pod

use nqp;
use Test::Async::Metamodel::HubHOW;
use Test::Async::Metamodel::BundleHOW;
use Test::Async::Metamodel::ReporterHOW;
use Test::Async::TestTool;

multi trait_mod:<is>(Method:D \meth, :$test-tool!) is export {
    my $tool-name = meth.name;
    my $readify = True;
    my $skippable = True;
    given $test-tool {
        when Str:D {
            $tool-name = $_;
        }
        when Hash:D | Pair:D {
            $tool-name = $_ with .<name>;
            $readify = $_ with .<readify>;
            $skippable = $_ with .<skip> // .<skippable>;
        }
        default {
            $tool-name = meth.name;
        }
    }
    meth does Test::Async::TestTool;
    meth.set-tool-name($tool-name);
    meth.set-readify($readify);
    meth.set-skippable($skippable);
}

sub EXPORT {
    use NQPHLL:from<NQP>;
    my role TestAsyncGrammar {
        token package_declarator:sym<test-hub> {
            :my $*OUTERPACKAGE := self.package;
            :my $*PKGDECL := 'test-hub';
            :my $*LINE_NO := HLL::Compiler.lineof(self.orig(), self.from(), :cache(1));
            <sym><.kok> <package_def>
            <.set_braid_from(self)>
        }
        token package_declarator:sym<test-bundle> {
            :my $*OUTERPACKAGE := self.package;
            :my $*PKGDECL := 'role';
            :my $*TEST-BUNDLE-TYPE;
            :my $*LINE_NO := HLL::Compiler.lineof(self.orig(), self.from(), :cache(1));
            <sym><.kok>
            { $*LANG.set_how('role', Test::Async::Metamodel::BundleHOW); }
            <package_def>
            <.set_braid_from(self)>
            { # XXX Possible problem if package_def fails - not sure if role's HOW would be restored.
              $*LANG.set_how('role', Metamodel::ParametricRoleHOW); }
        }
        token package_declarator:sym<test-reporter> {
            :my $*OUTERPACKAGE := self.package;
            :my $*PKGDECL := 'role';
            :my $*LINE_NO := HLL::Compiler.lineof(self.orig(), self.from(), :cache(1));
            :my $*TEST-BUNDLE-TYPE;
            <sym><.kok>
            { $*LANG.set_how('role', Test::Async::Metamodel::ReporterHOW); }
            <package_def>
            <.set_braid_from(self)>
            { # XXX Possible problem if package_def fails - not sure if role's HOW would be restored.
              $*LANG.set_how('role', Metamodel::ParametricRoleHOW); }
        }
    }

    my role TestAsyncActions {
        sub mkey ( Mu $/, Str:D $key ) {
            nqp::atkey(nqp::findmethod($/, 'hash')($/), $key)
        }

        method add_phaser(Mu $/) {
            my $blk := QAST::Block.new(
                QAST::Stmts.new,
                QAST::Stmts.new(
                    QAST::Op.new(
                        :op<callmethod>,
                        :name<register-bundle>,
                        QAST::WVal.new(:value(Test::Async::Metamodel::HubHOW)),
                        QAST::WVal.new(:value($*TEST-BUNDLE-TYPE))
                    )
                )
            );
            $*W.add_phaser($/, 'ENTER', $*W.create_code_obj_and_add_child($blk, 'Block'));
        }

        method package_declarator:sym<test-hub>(Mu $/) {
            $/.make( mkey($/, 'package_def').ast );
        }
        method package_declarator:sym<test-bundle>(Mu $/) {
            self.add_phaser($/);
            $/.make(mkey($/, 'package_def').ast);
        }
        method package_declarator:sym<test-reporter>(Mu $/) {
            self.add_phaser($/);
            $/.make(mkey($/, 'package_def').ast);
        }
    }

    unless $*LANG.^does( TestAsyncGrammar ) {
        $*LANG.set_how('test-hub', Test::Async::Metamodel::HubHOW);
        $ = $*LANG.define_slang(
            'MAIN',
            $*LANG.HOW.mixin($*LANG.WHAT,TestAsyncGrammar),
            $*LANG.actions.^mixin(TestAsyncActions)
        );
    }

    Map.new: ( EXPORT::DEFAULT:: )
}
