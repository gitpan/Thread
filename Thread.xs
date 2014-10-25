#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static I32 threadnum = 0;

static void *
threadstart(arg)
void *arg;
{
#ifdef FAKE_THREADS
    Thread savethread = thr;
    LOGOP myop;
    dSP;
    I32 oldscope = scopestack_ix;
    I32 retval;
    AV *returnav = newAV();
    int i;

    DEBUG_L(PerlIO_printf(PerlIO_stderr(), "new thread %p starting at %s\n",
			  thr, SvPEEK(TOPs)));
    thr = (Thread) arg;
    savemark = TOPMARK;
    thr->prev = thr->prev_run = savethread;
    thr->next = savethread->next;
    thr->next_run = savethread->next_run;
    savethread->next = savethread->next_run = thr;
    thr->wait_queue = 0;
    thr->private = 0;

    /* Now duplicate most of perl_call_sv but with a few twists */
    op = (OP*)&myop;
    Zero(op, 1, LOGOP);
    myop.op_flags = OPf_STACKED;
    myop.op_next = Nullop;
    myop.op_flags |= OPf_KNOW;
    myop.op_flags |= OPf_WANT_LIST;
    op = pp_entersub(ARGS);
    DEBUG_L(if (!op)
	    PerlIO_printf(PerlIO_stderr(), "thread starts at Nullop\n"));
    /*
     * When this thread is next scheduled, we start in the right
     * place. When the thread runs off the end of the sub, perl.c
     * handles things, using savemark to figure out how much of the
     * stack is the return value for any join.
     */
    thr = savethread;		/* back to the old thread */
    return 0;
#else
    Thread thr = (Thread) arg;
    LOGOP myop;
    dSP;
    I32 oldmark = TOPMARK;
    I32 oldscope = scopestack_ix;
    I32 retval;
    AV *returnav = newAV();
    int i;
    dJMPENV;
    int ret;

    /* Don't call *anything* requiring dTHR until after pthread_setspecific */
    /*
     * Wait until our creator releases us. If we didn't do this, then
     * it would be potentially possible for out thread to carry on and
     * do stuff before our creator fills in our "self" field. For example,
     * if we went and created another thread which tried to pthread_join
     * with us, then we'd be in a mess.
     */
    MUTEX_LOCK(threadstart_mutexp);
    MUTEX_UNLOCK(threadstart_mutexp);
    MUTEX_DESTROY(threadstart_mutexp);	/* don't need it any more */
    Safefree(threadstart_mutexp);

    /*
     * It's safe to wait until now to set the thread-specific pointer
     * from our pthread_t structure to our struct thread, since we're
     * the only thread who can get at it anyway.
     */
    if (pthread_setspecific(thr_key, (void *) thr))
	croak("panic: pthread_setspecific");

    /* Only now can we use SvPEEK (which calls sv_newmortal which does dTHR) */
    DEBUG_L(PerlIO_printf(PerlIO_stderr(), "new thread %p starting at %s\n",
			  thr, SvPEEK(TOPs)));

    JMPENV_PUSH(ret);
    switch (ret) {
    case 3:
        PerlIO_printf(PerlIO_stderr(), "panic: threadstart\n");
	/* fall through */
    case 1:
	STATUS_ALL_FAILURE;
	/* fall through */
    case 2:
	/* my_exit() was called */
	while (scopestack_ix > oldscope)
	    LEAVE;
	JMPENV_POP;
	av_store(returnav, 0, newSViv(statusvalue));
	goto finishoff;
    }

    /* Now duplicate most of perl_call_sv but with a few twists */
    op = (OP*)&myop;
    Zero(op, 1, LOGOP);
    myop.op_flags = OPf_STACKED;
    myop.op_next = Nullop;
    myop.op_flags |= OPf_KNOW;
    myop.op_flags |= OPf_WANT_LIST;
    op = pp_entersub(ARGS);
    if (op)
	runops();
    SPAGAIN;
    retval = sp - (stack_base + oldmark);
    sp = stack_base + oldmark + 1;
    DEBUG_L(for (i = 1; i <= retval; i++)
		PerlIO_printf(PerlIO_stderr(),
			      "%p returnav[%d] = %s\n",
			      thr, i, SvPEEK(sp[i - 1]));)
    av_store(returnav, 0, newSVpv("", 0));
    for (i = 1; i <= retval; i++, sp++)
	sv_setsv(*av_fetch(returnav, i, TRUE), SvREFCNT_inc(*sp));
    
  finishoff:
#if 0    
    /* removed for debug */
    SvREFCNT_dec(curstack);
#endif
    SvREFCNT_dec(cvcache);
    Safefree(markstack);
    Safefree(scopestack);
    Safefree(savestack);
    Safefree(retstack);
    Safefree(cxstack);
    Safefree(tmps_stack);

    if (ThrSTATE(thr) == THRf_DETACHED) {
	DEBUG_L(PerlIO_printf(PerlIO_stderr(),
			      "%p detached...zapping returnav\n", thr));
	SvREFCNT_dec(returnav);
	ThrSETSTATE(thr, THRf_DEAD);
    }
    DEBUG_L(PerlIO_printf(PerlIO_stderr(), "%p returning\n", thr));	
    return (void *) returnav;	/* Available for anyone to join with us */
				/* unless we are detached in which case */
				/* noone will see the value anyway. */
#endif    
}

static SV *
newthread(startsv, initargs, class)
SV *startsv;
AV *initargs;
char *class;
{
    dTHR;
    dSP;
    Thread savethread;
    int i;
    SV *sv;
    
    savethread = thr;
    sv = newSVpv("", 0);
    SvGROW(sv, sizeof(struct thread) + 1);
    SvCUR_set(sv, sizeof(struct thread));
    thr = (Thread) SvPVX(sv);
    oursv = sv; 
    /* If we don't zero these foostack pointers, init_stacks won't init them */
    markstack = 0;
    scopestack = 0;
    savestack = 0;
    retstack = 0;
    init_stacks(ARGS);
    curcop = savethread->Tcurcop;	/* XXX As good a guess as any? */
    SPAGAIN;
    defstash = savethread->Tdefstash;	/* XXX maybe these should */
    curstash = savethread->Tcurstash;	/* always be set to main? */
    /* top_env? */
    /* runlevel */
    cvcache = newHV();
    thrflags = 0;
    ThrSETSTATE(thr, THRf_NORMAL);

    /* The following pushes the arg list and startsv onto the *new* stack */
    PUSHMARK(sp);
    /* Could easily speed up the following greatly */
    for (i = 0; i <= AvFILL(initargs); i++)
	XPUSHs(SvREFCNT_inc(*av_fetch(initargs, i, FALSE)));
    XPUSHs(SvREFCNT_inc(startsv));
    PUTBACK;

#ifdef FAKE_THREADS
    threadstart(thr);
#else    
    New(53, threadstart_mutexp, 1, perl_mutex);
    /* On your marks... */
    MUTEX_INIT(threadstart_mutexp);
    MUTEX_LOCK(threadstart_mutexp);
    /* Get set...
     * Increment the global thread count. It is decremented
     * by the destructor for the thread specific key thr_key.
     */
    MUTEX_LOCK(&nthreads_mutex);
    nthreads++;
    MUTEX_UNLOCK(&nthreads_mutex);
    if (pthread_create(&self, NULL, threadstart, (void*) thr))
	return NULL;	/* XXX should clean up first */
    /* Go */
    MUTEX_UNLOCK(threadstart_mutexp);
#endif
    sv = newSViv(++threadnum);
    sv_magic(sv, oursv, '~', 0, 0);
    return sv_bless(newRV(sv), gv_stashpv(class, TRUE));
}

MODULE = Thread		PACKAGE = Thread

void
new(class, startsv, ...)
	char *		class
	SV *		startsv
	AV *		av = av_make(items - 2, &ST(2));
    PPCODE:
	XPUSHs(sv_2mortal(newthread(startsv, av, class)));

void
join(t)
	Thread	t
	AV *	av = NO_INIT
	int	i = NO_INIT
    PPCODE:
	DEBUG_L(PerlIO_printf(PerlIO_stderr(),
			      "%p: joining %p (state 0x%lx)\n",
			      thr, t, (unsigned long)ThrSTATE(t)););
	if (ThrSTATE(t) == THRf_DETACHED)
	    croak("tried to join a detached thread");
	else if (ThrSTATE(t) == THRf_JOINED)
	    croak("tried to rejoin an already joined thread");
	else if (ThrSTATE(t) == THRf_DEAD)
	    croak("tried to join a dead thread");

	if (pthread_join(t->Tself, (void **) &av))
	    croak("pthread_join failed");
	ThrSETSTATE(t, THRf_JOINED);
	/* Could easily speed up the following if necessary */
	for (i = 0; i <= AvFILL(av); i++)
	    XPUSHs(sv_2mortal(*av_fetch(av, i, FALSE)));

void
detach(t)
	Thread	t
    CODE:
	DEBUG_L(PerlIO_printf(PerlIO_stderr(),
			      "%p: detaching %p (state 0x%lx)\n",
			      thr, t, (unsigned long)ThrSTATE(t)););
	if (ThrSTATE(t) == THRf_DETACHED)
	    croak("tried to detach an already detached thread");
	else if (ThrSTATE(t) == THRf_JOINED)
	    croak("tried to detach an already joined thread");
	else if (ThrSTATE(t) == THRf_DEAD)
	    croak("tried to detach a dead thread");
	if (pthread_detach(t->Tself))
	    croak("panic: pthread_detach failed");
	ThrSETSTATE(t, THRf_DETACHED);

void
DESTROY(t)
	Thread	t
    CODE:
	if (ThrSTATE(t) == THRf_NORMAL) {
	    if (pthread_detach(t->Tself))
		croak("panic: pthread_detach failed");
	    ThrSETSTATE(t, THRf_DETACHED);
	    thrflags |= THRf_DIE_FATAL;
	}

void
yield()
    CODE:
#ifdef OLD_PTHREADS_API
	pthread_yield();
#else
#ifndef NO_SCHED_YIELD
	sched_yield();
#endif /* NO_SCHED_YIELD */
#endif /* OLD_PTHREADS_API */

void
cond_wait(sv)
	SV *	sv
	MAGIC *	mg = NO_INIT
CODE:
	if (SvROK(sv))
	    sv = SvRV(sv);

	mg = condpair_magic(sv);
	DEBUG_L(PerlIO_printf(PerlIO_stderr(), "%p: cond_wait %p\n", thr, sv));
	MUTEX_LOCK(MgMUTEXP(mg));
	if (MgOWNER(mg) != thr) {
	    MUTEX_UNLOCK(MgMUTEXP(mg));
	    croak("cond_wait for lock that we don't own\n");
	}
	MgOWNER(mg) = 0;
	COND_WAIT(MgCONDP(mg), MgMUTEXP(mg));
	MgOWNER(mg) = thr;
	MUTEX_UNLOCK(MgMUTEXP(mg));
	
void
cond_signal(sv)
	SV *	sv
	MAGIC *	mg = NO_INIT
CODE:
	if (SvROK(sv)) {
	    /*
	     * Kludge to allow lock of real objects without requiring
	     * to pass in every type of argument by explicit reference.
	     */
	    sv = SvRV(sv);
	}
	mg = condpair_magic(sv);
	DEBUG_L(PerlIO_printf(PerlIO_stderr(), "%p: cond_signal %p\n",thr,sv));
	MUTEX_LOCK(MgMUTEXP(mg));
	if (MgOWNER(mg) != thr) {
	    MUTEX_UNLOCK(MgMUTEXP(mg));
	    croak("cond_signal for lock that we don't own\n");
	}
	COND_SIGNAL(MgCONDP(mg));
	MUTEX_UNLOCK(MgMUTEXP(mg));

void
cond_broadcast(sv)
	SV *	sv
	MAGIC *	mg = NO_INIT
CODE:
	if (SvROK(sv))
	    sv = SvRV(sv);

	mg = condpair_magic(sv);
	DEBUG_L(PerlIO_printf(PerlIO_stderr(), "%p: cond_broadcast %p\n",
			      thr, sv));
	MUTEX_LOCK(MgMUTEXP(mg));
	if (MgOWNER(mg) != thr) {
	    MUTEX_UNLOCK(MgMUTEXP(mg));
	    croak("cond_broadcast for lock that we don't own\n");
	}
	COND_BROADCAST(MgCONDP(mg));
	MUTEX_UNLOCK(MgMUTEXP(mg));
