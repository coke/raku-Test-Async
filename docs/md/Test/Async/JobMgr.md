NAME
====

`Test::Async::JobMgr` – job management role

SYNOPSIS
========

    class MyApp does Test::Async::JobMgr {
        method foo {
            self.start-job: self.new-job( { self.worker-method }, :async );
        }
        method shutdown {
            self.await-all-jobs;
        }
    }

DESCRIPTION
===========



This role implements job management functionality, as described in section Job Management of [`Test::Async::Manual`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Manual.md). 

Implementation Details
----------------------

All jobs are kept in unordered "pool" and identified either by the object representing them, or by unique numeric ID assigned to each job.

Jobs are grouped into three categories:

  * *active* - managed jobs, whose maximum number of concurrent instances is limited. Start with `start-job`.

  * *postponed* – jobs which are to be invoked later, when the consuming class decides it.

  * *waiting* - those scheduled for execution but awaiting for a free slot.

A completed job is removed from the pool automatically, the user code doesn't need to worry about this.

ATTRIBUTES
==========



`@.postponed`
-------------

Queue of jobs postponed for later invocation. Not actually used by the manager itself except by `await-all-jobs` methods. Provided for consuming class code convenience.

METHODS
=======



`test-job()`
------------

A stub. Consuming class must provide it to report the maximum number of simultaneously executed jobs. See `$.test-jobs` attribute of [`Test::Async::Hub`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Hub.md), for example.

`job-count(--` Int)>
--------------------

The total number of jobs in the job pool. Includes currently running ones.

`new-job(Callable:D \code, :$async = False)`
--------------------------------------------

Creates a new job instance of [`Test::Async::Job`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Job.md) for `code` parameter. `$async` is used to mark the job as explicitly asynchronous.

`all-job-promises(--` Seq)>
---------------------------

Returns promises of all jobs except those not invoked yet.

`active-job-promises(--` Seq)>
------------------------------

Returns promises of "active" jobs; i.e. those started with `start-job` method and currently being executed. Note that those, invoked using `start` method won't be included into the list.

`mutli release-job(Int:D $id)`
------------------------------

`multi release-job(Test::Async::Job:D $job)`
--------------------------------------------

Removes a job from the pool. Usually there is no need for user code to call it.

`multi postpone(Callable:D \code, :$async = False)`
---------------------------------------------------

`multi postpone(Test::Async::Job:D $job)`
-----------------------------------------

Pushes a job into `@.postpone` queue.

`job-by-id(Int:D $id --` Test::Async::Job)>
-------------------------------------------

Returns job object with `$id` or throws `X::NoJobId`.

`multi start-job(Int:D $id --` Promise)>
----------------------------------------

`multi start-job(Callable \code --` Promise)>
---------------------------------------------

`multi start-job(Test::Async::Job:D $job --` Promise)>
------------------------------------------------------

If there are fewer running jobs than `test-jobs` then method starts the job asynchronously. Otherwise the job is put on the waiting queue. As soon as active jobs complete, the next job on the waiting queue gets defrost and invoked.

`multi start(Int:D $id --` Promise)>
------------------------------------

`multi start(Callable:D \code --` Promise)>
-------------------------------------------

`multi start(Test::Async::Job:D $job --` Promise)>
--------------------------------------------------

Similarly to Raku's `start` statement, this method starts a job instantly in a new thread. The difference though is that a job started with this method is a subject for awaiting with `await-all-jobs` method and is auto-removed from the job pool when completed.

Jobs started with this method are not limited with `test-jobs` value. Neither their're accounted by `start-job` method.

`multi invoke-job(Int:D $id --` Promise)>
-----------------------------------------

`multi invoke-job(Test::Async::Job:D $job --` Promise)>
-------------------------------------------------------

Invokes a job instantly. If job is marked as `async` then it is started with `start` method, listed above. Otherwise job code is invoked instantly in the current thread.

Returns a [`Promise`](https://docs.raku.org/type/Promise) kept with job code return value.

`await-all-jobs()`
------------------

Awaits for all running jobs to complete. If there are pending ones they'd be awaited too. The method returns when the job pool is emptied.

Note that if the method encounters non-empty queue of postponed jobs it throws `X::AwaitWithPostponed`. This is because any exiting postponed job would likely cause the job pool to remain non-empty forever.

SEE ALSO
========

[`Test::Async::Manual`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Manual.md), [`Test::Async::Job`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/Job.md), [`Test::Async::X`](https://github.com/vrurg/raku-Test-Async/blob/v0.0.1/docs/md/Test/Async/X.md)

AUTHOR
======

Vadim Belman <vrurg@lflat.org>
