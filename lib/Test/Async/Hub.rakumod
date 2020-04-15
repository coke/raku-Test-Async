use v6;
use Test::Async::Decl;
unit test-hub Test::Async::Hub;

use Test::Async::Aggregator;
use Test::Async::JobMgr;
use Test::Async::Utils;
use Test::Async::Event;
use Test::Async::TestTool;
use Test::Async::Result;
use Test::Async::X;

also does Test::Async::Aggregator;
also does Test::Async::JobMgr;

has ::?CLASS $.parent-suite;

# Message associated with this suite. Only makes sense for children.
has $.message;
# Test code block we will invoke.
has &.code;

# This is what we start with.
has TestStage:D $.stage is built(False) = TSInitializing;
has Promise:D $.completed .= new;
has $!completed-vow = $!completed.vow;
has Int $.planned;
# A message set with skip-rest
has Str $.skip-message;
has Str:D $.TODO-message = "";
has Numeric:D $.TODO-count = 0;
# How far away our hub from the top one?
has Int:D $.nesting = 0;
has Str:D $.nesting-prefix = "  ";

# Are we an asynchronous child? Transitive, i.e. event if the suit is started synchronously by a parent but the parent
# itself is async – this becomes true.
has Bool:D $.is-async = False;
# If the whole suite is TODOed
has Bool:D $.is-TODO = False;
# Run children in random order.
has Bool $.random;

has atomicint $!next-test-id = 1;
has atomicint $.tests-run = 0;
has atomicint $.tests-failed = 0;

# Run children in individual threads
has Bool $.parallel;
# Messages collected during test code run.
has Str:D @.messages;
# How many jobs can be invoked in parallel.
has UInt:D $.test-jobs = (try { %*ENV<TEST_JOBS>.Int } || ($*KERNEL.cpu-cores - 2)) max 1;

method new(|c) {
    # This class is already mutated into a suit
    nextsame if self.^suite;
    self.^construct_suite.new(|c)
}

my $singleton;
method top-suite {
    $singleton //= ::?CLASS.new
}

method test-suite {
    $*TEST-SUITE // self.top-suite
}

my @stage-equivalence = TSInitializing, TSInProgress, TSInProgress, TSFinished, TSDismissed;

method set-stage(TestStage:D $stage) {
    return $!stage if $!stage == $stage;
    loop {
        my $cur-stage = $!stage;
        # Prevent possible race condition when two concurrent locations are trying to set different states.
        # States are defined by the equivalence table.
        self.throw: X::StageTransition, :from($cur-stage), :to($stage)
            if @stage-equivalence[$cur-stage] > @stage-equivalence[$stage];
        # Do nothing if requested stage is equivalent to the current one but preceeds it.
        return $cur-stage if $cur-stage > $stage;
        if cas($!stage, $cur-stage, $stage) == $cur-stage {
            self.start-event-loop if $cur-stage == TSInitializing;
            return $cur-stage;
        }
    }
}

proto method event(::?CLASS:D: Event:D) {*}
multi method event(::?CLASS:D: Event::Command:D $ev) {
    my $cmd-name = $ev.^name
                    .split( '::' )
                    .grep({ "Event" ^ff * })
                    .map( *.lc )
                    .join( '-' );
    self."$cmd-name"(|$ev.args);
}
multi method event(::?CLASS:D: Event::Report:D $ev) {
    self.report-event($ev);
    nextsame
}
# Drop unprocessed events.
multi method event(Event:D) { }

method setup-from-plan(%plan) {
    my $cur-stage = %plan<tests>:exists ?? $.set-stage(TSInProgress) !! $!stage;
    if $cur-stage != TSInitializing {
        warn "It is too late to change plan at " ~ $*TEST-CALLER.gist;
    }
    else {
        if %plan<tests> {
            $!planned = %plan<tests>:delete;
        }
        if %plan<skip-all> {
            $!skip-message = %plan<skip-all>:delete;
        }
        if %plan<todo> {
            $!TODO-message = %plan<todo>:delete;
            $!TODO-count = Inf;
            $!is-TODO = True;
        }
        $!parallel = .so with %plan<parallel>:delete;
        $!random = .so with %plan<random>:delete;
        if $!planned {
            self.send-plan($!planned, :on-start);
        }
        if %plan {
            self.send: Event::Diag, :message("Unknown plan parameter: " ~ $_) for %plan.keys;
        }
    }
}

proto method plan(|) is test-tool(:!readify) {*}
multi method plan(UInt:D $tests, *%plan) {
    %plan<tests> = $tests;
    self.setup-from-plan: %plan;
}
multi method plan(*%plan) {
    self.setup-from-plan: %plan;
}
multi method plan(%plan) {
    self.setup-from-plan: %plan;
}

method done-testing() is test-tool(:!skippable) {
    self.finish;
}

method cmd-skipremaining(Str:D $message) {
    $!skip-message = $message;
}

method cmd-syncevents($vow) {
    $vow.keep(True);
}

# Excepts normalized message
method cmd-message(+@message) {
    # say "++ COLLECTED: <<", @message.join("//"), ">>";
    @!messages.append: @message;
}

method cmd-settodo(Str:D $!TODO-message, Numeric:D $!TODO-count) { }

method create-suite(::?CLASS:U \suiteType = self.WHAT, *%c) {
    my %profile = :parent-suite(self), :nesting($!nesting + 1), :$!random;
    if my $TODO-message = self.take-TODO {
        # If a subtest falls under a todo then all its tests are todo
        %profile.append: (:$TODO-message, :is-TODO);
    }
    suiteType.new: |%profile, |%c
}

method invoke-suite(::?CLASS:D $suite, Bool:D :$async = False, Bool:D :$instant = False) {
    my $is-async = $async || ($!parallel && !$instant);
    my $job = self.new-job: { 
        $suite.run(:$is-async) 
    }, :$async;
    if $!random && $!stage == TSInProgress && !$instant {
        self.postpone: $job;
    }
    elsif $is-async {
        self.start-job: $job;
    }
    else {
        self.invoke-job: $job;
    }
    $suite.completed
}

method run(:$is-async) {
    # If any parent is async all its children are async too.
    $!is-async = ($!parent-suite && $!parent-suite.is-async) || ?$is-async;
    my $*TEST-SUITE = self;
    &!code();
    self.done-testing;
}

method throw(X::Base:U \exType, *%c) {
    exType.new( :hub(self), |%c ).throw
}

method send-command(Event::Command:U \evType, |c) {
    self.send: evType, :args(c)
}

method send-test(Event::Test:U \evType, Str:D $message, TestResult:D $tr, *%c) {
    my %profile;
    ++⚛$!tests-run;
    if $tr == TRFailed && !($!TODO-count || $!is-TODO) {
        ++⚛$!tests-failed;
    }
    if my $TODO-message = self.take-TODO {
        %profile<todo> = $TODO-message;
    }
    %profile<test-id> = self.next-test-id;
    %profile<caller> = $*TEST-CALLER;
    self.send: evType, :$message, |%profile, |%c;
    $tr == TRPassed
}

method send-plan(UInt:D $planned, :$on-start) {
    # say "send plan of $planned, on start? ", ?$on-start;
    # say "skip message: “{$!skip-message || '*none*'}”";
    if $on-start && !$!parent-suite && $!skip-message {
        self.report-event: Event::Plan.new( :origin(self), :skip, :message($!skip-message), :planned(0) );
        exit 0;
    }
    self.send: Event::Plan, :$planned;
}

# Normal message form is a list of lines ending with newline.
method normalize-message(@message) {
    @message.join.split("\n").map(* ~ "\n")
}

method send-message(+@message) {
    my @msg = self.normalize-message(@message);
    if $!parent-suite && $!is-async {
        # Collect the message if weo're an async child
        self.send-command: Event::Cmd::Message, @msg;
    }
    else {
        self.message-to-console: @msg;
    }
}

proto method proclaim(|) {*}
multi method proclaim(Test::Async::Result:D $result, Str:D $message) {
    self.proclaim(.cond, $message, .event-profile) given $result;
}
multi method proclaim(Bool(Mu) $cond, Str:D $message, $event-profile = \()) {
    my (\evType, $test-result) := $cond ?? (Event::Ok, TRPassed) !! (Event::NotOk, TRFailed);
    my %profile = :origin(self), :@!messages, :$!nesting;
    self.send-test(evType, $message, $test-result, |%profile, |$event-profile);
}

method next-test-id {
    loop {
        my $cur-id = $!next-test-id;
        if cas($!next-test-id, $cur-id, $cur-id + 1) == $cur-id {
            return $cur-id;
        }
    }
}

method take-TODO {
    return Nil unless $!is-TODO || $!TODO-count > 0;
    --$!TODO-count unless $!is-TODO;
    $!TODO-message
}

method set-todo(Str:D $message, Numeric:D $count) {
    self.send-command: Event::Cmd::SetTODO, $message, $count;
}

method sync-events {
    my $synced = Promise.new;
    $.send-command: Event::Cmd::SyncEvents, $synced.vow;
    await $synced;
}

method await-jobs {
    if $!random {
        # Get randomized list of children
        for @.postponed.pick(*) -> $job {
            self.invoke-job: $job
        }
        @.postponed = [];
    }
    my $all-done;
    await Promise.anyof(
        Promise.in(30).then({ note "TOUT"; cas($all-done, Any, False); }),
        start { 
            CATCH { note $_; exit 255 }; 
            self.await-all-jobs; 
            cas($all-done, Any, True); 
        }
    );
    self.throw(X::AwaitTimeout, :what('all jobs')) unless $all-done;
}

method finish {
    # Only do the sequence once even if accidentally called concurrently.
    return if $!stage == TSFinishing | TSDismissed;
    if self.set-stage(TSFinishing) == TSInProgress {
        # Wait untils all jobs are completed.
        self.await-jobs; 
        self.set-stage(TSFinished);
        self.sync-events;
        # Let all event be processed before we start analyzing the results.
        # Same as plan, done-testing must be done in the main thread.
        self.send-plan: $!tests-run unless $.planned; # If $.planned is set then the plan has been reported on start.
        self.send: Event::DoneTesting;
        self.sync-events; # Wait until all queued events processed;
        self.send: Event::Terminate, :completed($!completed-vow);
        await $!completed;
        self.set-stage(TSDismissed);
    }
}

method measure-telemetry(&code, Capture:D \c = \()) is hidden-from-backtrace is raw {
    my $st = now;
    LEAVE {
        my $et = now;
        self.send: Event::Telemetry, :elapsed($et-$st)
    }
    &code(|c)
}

# Returns a list of "&tool-name" => &code pairs
method tool-factory(--> Seq:D) {
    self.^methods
        .grep(Test::Async::TestTool)
        .map: -> \meth {
            my $name = meth.tool-name;
            my $meth = meth.name;
            my &code = my sub (|c) is raw { ::?CLASS.test-suite."$meth"(|c) };
            &code.set_name($name);
            "&" ~ $name => &code
        }
}
