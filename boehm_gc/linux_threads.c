/* 
 * Copyright (c) 1994 by Xerox Corporation.  All rights reserved.
 * Copyright (c) 1996 by Silicon Graphics.  All rights reserved.
 * Copyright (c) 1998 by Fergus Henderson.  All rights reserved.
 *
 * THIS MATERIAL IS PROVIDED AS IS, WITH ABSOLUTELY NO WARRANTY EXPRESSED
 * OR IMPLIED.  ANY USE IS AT YOUR OWN RISK.
 *
 * Permission is hereby granted to use or copy this program
 * for any purpose,  provided the above notices are retained on all copies.
 * Permission to modify the code and to distribute modified code is granted,
 * provided the above notices are retained, and a notice that the code was
 * modified is included with the above copyright notice.
 */
/*
 * Support code for LinuxThreads, the clone()-based kernel
 * thread package for Linux which is included in libc6.
 *
 * This code relies on implementation details of LinuxThreads,
 * (i.e. properties not guaranteed by the Pthread standard):
 *
 *	- it uses `kill(SIGSTOP, getpid())' to suspend the
 *	  current thread.  According to POSIX, this should
 *	  stop the whole process, not just the thread.
 *	  (An alternative would be to use
 *	  `pthread_kill(SIGSTOP, pthread_self())' instead,
 *	  but we need to do it inside a signal handler,
 *	  and the pthread_kill() implementation in LinuxThreads
 *	  is not async-signal-safe.)
 *
 *	- the function GC_linux_thread_top_of_stack(void)
 *	  relies on the way LinuxThreads lays out thread stacks
 *	  in the address space.
 *
 * Note that there is a lot of code duplication between linux_threads.c
 * and irix_threads.c; any changes made here may need to be reflected
 * there too.
 */

# if defined(LINUX_THREADS)

# include "gc_priv.h"
# include <pthread.h>
# include <time.h>
# include <errno.h>
# include <unistd.h>
# include <sys/mman.h>
# include <sys/time.h>
# include <semaphore.h>

#undef pthread_create
#undef pthread_sigmask
#undef pthread_join

void GC_thr_init();

#if 0
void GC_print_sig_mask()
{
    sigset_t blocked;
    int i;

    if (pthread_sigmask(SIG_BLOCK, NULL, &blocked) != 0)
    	ABORT("pthread_sigmask");
    GC_printf0("Blocked: ");
    for (i = 1; i <= MAXSIG; i++) {
        if (sigismember(&blocked, i)) { GC_printf1("%ld ",(long) i); }
    }
    GC_printf0("\n");
}
#endif

/* We use the allocation lock to protect thread-related data structures. */

/* The set of all known threads.  We intercept thread creation and 	*/
/* joins.  We never actually create detached threads.  We allocate all 	*/
/* new thread stacks ourselves.  These allow us to maintain this	*/
/* data structure.							*/
/* Protected by GC_thr_lock.						*/
/* Some of this should be declared volatile, but that's incosnsistent	*/
/* with some library routine declarations.  		 		*/
typedef struct GC_Thread_Rep {
    struct GC_Thread_Rep * next;  /* More recently allocated threads	*/
				  /* with a given pthread id come 	*/
				  /* first.  (All but the first are	*/
				  /* guaranteed to be dead, but we may  */
				  /* not yet have registered the join.) */
    pthread_t id;
    word flags;
#	define FINISHED 1   	/* Thread has exited.	*/
#	define DETACHED 2	/* Thread is intended to be detached.	*/
#	define MAIN_THREAD 4	/* True for the original thread only.	*/

    ptr_t stack_end;
    ptr_t stack_ptr;  		/* Valid only when stopped. */
    int	signal;
    void * status;		/* The value returned from the thread.  */
    				/* Used only to avoid premature 	*/
				/* reclamation of any data it might 	*/
				/* reference.				*/
} * GC_thread;

GC_thread GC_lookup_thread(pthread_t id);

/*
 * The only way to suspend threads given the pthread interface is to send
 * signals.  We can't use SIGSTOP directly, because we need to get the
 * thread to save its stack pointer in the GC thread table before
 * suspending.  So we have to reserve a signal of our own for this.
 * This means we have to intercept client calls to change the signal mask.
 * The linuxthreads package already uses SIGUSR1 and SIGUSR2,
 * so we need to reuse something else.  I chose SIGPWR.
 * (Perhaps SIGUNUSED would be a better choice.)
 */
#define SIG_SUSPEND SIGPWR

#define SIG_RESTART SIGCONT

sem_t GC_suspend_ack_sem;

/*
GC_linux_thread_top_of_stack() relies on implementation details of
LinuxThreads, namely that thread stacks are allocated on 2M boundaries
and grow to no more than 2M.
To make sure that we're using LinuxThreads and not some other thread
package, we generate a dummy reference to `__pthread_initial_thread_bos',
which is a symbol defined in LinuxThreads, but (hopefully) not in other
thread packages.
*/
extern char * __pthread_initial_thread_bos;
char **dummy_var_to_force_linux_threads = &__pthread_initial_thread_bos;

#define LINUX_THREADS_STACK_SIZE  (2 * 1024 * 1024)

static inline ptr_t GC_linux_thread_top_of_stack(void)
{
  char *sp = GC_approx_sp();
  ptr_t tos = (ptr_t) (((unsigned long)sp | (LINUX_THREADS_STACK_SIZE - 1)) + 1);
#if DEBUG_THREADS
  GC_printf1("SP = %lx\n", (unsigned long)sp);
  GC_printf1("TOS = %lx\n", (unsigned long)tos);
#endif
  return tos;
}

void GC_suspend_handler(int sig)
{
    int dummy;
    pthread_t my_thread = pthread_self();
    GC_thread me;
    sigset_t all_sigs;
    sigset_t old_sigs;
    int i;
    sigset_t mask;

    if (sig != SIG_SUSPEND) ABORT("Bad signal in suspend_handler");

#if DEBUG_THREADS
    GC_printf1("Suspending 0x%x\n", my_thread);
#endif

    me = GC_lookup_thread(my_thread);
    /* The lookup here is safe, since I'm doing this on behalf  */
    /* of a thread which holds the allocation lock in order	*/
    /* to stop the world.  Thus concurrent modification of the	*/
    /* data structure is impossible.				*/
    me -> stack_ptr = (ptr_t)(&dummy);
    me -> stack_end = GC_linux_thread_top_of_stack();

    /* Tell the thread that wants to stop the world that this   */
    /* thread has been stopped.  Note that sem_post() is  	*/
    /* the only async-signal-safe primitive in LinuxThreads.    */
    sem_post(&GC_suspend_ack_sem);

    /* Wait until that thread tells us to restart by sending    */
    /* this thread a SIG_RESTART signal.			*/
    if (sigfillset(&mask) != 0) ABORT("sigfillset() failed");
    if (sigdelset(&mask, SIG_RESTART) != 0) ABORT("sigdelset() failed");
    if (sigdelset(&mask, SIG_SUSPEND) != 0) ABORT("sigdelset() failed");
    do {
	    me->signal = 0;
	    sigsuspend(&mask);             /* Wait for signal */
    } while (me->signal != SIG_RESTART);

#if DEBUG_THREADS
    GC_printf1("Continuing 0x%x\n", my_thread);
#endif
}

void GC_restart_handler(int sig)
{
    GC_thread me;

    if (sig != SIG_RESTART) ABORT("Bad signal in suspend_handler");

    /* Let the GC_suspend_handler() know that we got a SIG_RESTART. */
    /* The lookup here is safe, since I'm doing this on behalf  */
    /* of a thread which holds the allocation lock in order	*/
    /* to stop the world.  Thus concurrent modification of the	*/
    /* data structure is impossible.				*/
    me = GC_lookup_thread(pthread_self());
    me->signal = SIG_RESTART;

    /*
    ** Note: even if we didn't do anything useful here,
    ** it would still be necessary to have a signal handler,
    ** rather than ignoring the signals, otherwise
    ** the signals will not be delivered at all, and
    ** will thus not interrupt the sigsuspend() above.
    */

#if DEBUG_THREADS
    GC_printf1("In GC_restart_handler for 0x%x\n", pthread_self());
#endif
}

bool GC_thr_initialized = FALSE;

# define THREAD_TABLE_SZ 128	/* Must be power of 2	*/
volatile GC_thread GC_threads[THREAD_TABLE_SZ];

/* Add a thread to GC_threads.  We assume it wasn't already there.	*/
/* Caller holds allocation lock.					*/
GC_thread GC_new_thread(pthread_t id)
{
    int hv = ((word)id) % THREAD_TABLE_SZ;
    GC_thread result;
    static struct GC_Thread_Rep first_thread;
    static bool first_thread_used = FALSE;
    
    if (!first_thread_used) {
    	result = &first_thread;
    	first_thread_used = TRUE;
    	/* Dont acquire allocation lock, since we may already hold it. */
    } else {
        result = (struct GC_Thread_Rep *)
        	 GC_generic_malloc_inner(sizeof(struct GC_Thread_Rep), NORMAL);
    }
    if (result == 0) return(0);
    result -> id = id;
    result -> next = GC_threads[hv];
    GC_threads[hv] = result;
    /* result -> flags = 0; */
    return(result);
}

/* Delete a thread from GC_threads.  We assume it is there.	*/
/* (The code intentionally traps if it wasn't.)			*/
/* Caller holds allocation lock.				*/
void GC_delete_thread(pthread_t id)
{
    int hv = ((word)id) % THREAD_TABLE_SZ;
    register GC_thread p = GC_threads[hv];
    register GC_thread prev = 0;
    
    while (!pthread_equal(p -> id, id)) {
        prev = p;
        p = p -> next;
    }
    if (prev == 0) {
        GC_threads[hv] = p -> next;
    } else {
        prev -> next = p -> next;
    }
}

/* If a thread has been joined, but we have not yet		*/
/* been notified, then there may be more than one thread 	*/
/* in the table with the same pthread id.			*/
/* This is OK, but we need a way to delete a specific one.	*/
void GC_delete_gc_thread(pthread_t id, GC_thread gc_id)
{
    int hv = ((word)id) % THREAD_TABLE_SZ;
    register GC_thread p = GC_threads[hv];
    register GC_thread prev = 0;

    while (p != gc_id) {
        prev = p;
        p = p -> next;
    }
    if (prev == 0) {
        GC_threads[hv] = p -> next;
    } else {
        prev -> next = p -> next;
    }
}

/* Return a GC_thread corresponding to a given thread_t.	*/
/* Returns 0 if it's not there.					*/
/* Caller holds  allocation lock or otherwise inhibits 		*/
/* updates.							*/
/* If there is more than one thread with the given id we 	*/
/* return the most recent one.					*/
GC_thread GC_lookup_thread(pthread_t id)
{
    int hv = ((word)id) % THREAD_TABLE_SZ;
    register GC_thread p = GC_threads[hv];
    
    while (p != 0 && !pthread_equal(p -> id, id)) p = p -> next;
    return(p);
}

extern volatile int volatile_counter;
volatile int prev_counter;

/* Caller holds allocation lock.	*/
void GC_stop_world()
{
    pthread_t my_thread = pthread_self();
    register int i;
    register GC_thread p;
    register int n_live_threads = 0;
    register int result;

    /*
     * It is important to ensure that any threads which were
     * previously stopped and then woken get time to actually
     * wake up before we stop then again.  Otherwise,
     * we might try to suspend a process that is already
     * stopped, and I think that might not work properly.
     * Hence the following call to sched_yield().
     */
    sched_yield();
    
    for (i = 0; i < THREAD_TABLE_SZ; i++) {
      for (p = GC_threads[i]; p != 0; p = p -> next) {
        if (p -> id != my_thread) {
            if (p -> flags & FINISHED) continue;
            n_live_threads++;
	    #if DEBUG_THREADS
	      GC_printf1("Sending suspend signal to 0x%x\n", p -> id);
	    #endif
            result = pthread_kill(p -> id, SIG_SUSPEND);
	    switch(result) {
                case ESRCH:
                    /* Not really there anymore.  Possible? */
                    n_live_threads--;
                    break;
                case 0:
                    break;
                default:
                    ABORT("pthread_kill failed");
            }
        }
      }
    }
    for (i = 0; i < n_live_threads; i++) {
    	sem_wait(&GC_suspend_ack_sem);
    }
    #if DEBUG_THREADS
    GC_printf1("World stopped 0x%x\n", pthread_self());
    #endif
    prev_counter = volatile_counter;
}

/* Caller holds allocation lock.	*/
void GC_start_world()
{
    pthread_t my_thread = pthread_self();
    register int i;
    register GC_thread p;
    register int n_live_threads = 0;
    register int result;
    
    if (volatile_counter != prev_counter) {
	ABORT("GC_stop_world didn't stop everything");
    }
    #if DEBUG_THREADS
      GC_printf0("World starting\n");
    #endif

    for (i = 0; i < THREAD_TABLE_SZ; i++) {
      for (p = GC_threads[i]; p != 0; p = p -> next) {
        if (p -> id != my_thread) {
            if (p -> flags & FINISHED) continue;
            n_live_threads++;
	    #if DEBUG_THREADS
	      GC_printf1("Sending restart signal to 0x%x\n", p -> id);
	    #endif
            result = pthread_kill(p -> id, SIG_RESTART);
	    switch(result) {
                case ESRCH:
                    /* Not really there anymore.  Possible? */
                    n_live_threads--;
                    break;
                case 0:
                    break;
                default:
                    ABORT("pthread_kill failed");
            }
        }
      }
    }
    #if DEBUG_THREADS
      GC_printf0("World started\n");
    #endif
}

/* We hold allocation lock.  We assume the world is stopped.	*/
void GC_push_all_stacks()
{
    register int i;
    register GC_thread p;
    register ptr_t sp = GC_approx_sp();
    register ptr_t lo, hi;
    pthread_t me = pthread_self();
    
    if (!GC_thr_initialized) GC_thr_init();
    #if DEBUG_THREADS
        GC_printf1("Pushing stacks from thread 0x%lx\n", (unsigned long) me);
    #endif
    for (i = 0; i < THREAD_TABLE_SZ; i++) {
      for (p = GC_threads[i]; p != 0; p = p -> next) {
        if (p -> flags & FINISHED) continue;
        if (pthread_equal(p -> id, me)) {
	    lo = GC_approx_sp();
	} else {
	    lo = p -> stack_ptr;
	}
        if ((p -> flags & MAIN_THREAD) == 0) {
	    if (pthread_equal(p -> id, me)) {
		hi = GC_linux_thread_top_of_stack();
	    } else {
		hi = p -> stack_end;
	    }
        } else {
            /* The original stack. */
            hi = GC_stackbottom;
        }
        #if DEBUG_THREADS
            GC_printf3("Stack for thread 0x%lx = [%lx,%lx)\n",
    	        (unsigned long) p -> id,
		(unsigned long) lo, (unsigned long) hi);
        #endif
        GC_push_all_stack(lo, hi);
      }
    }
}


/* We hold the allocation lock.	*/
void GC_thr_init()
{
    GC_thread t;
    struct sigaction act;

    GC_thr_initialized = TRUE;

    if (sem_init(&GC_suspend_ack_sem, 0, 0) != 0)
    	ABORT("sem_init failed");

    act.sa_flags = SA_RESTART;
    if (sigfillset(&act.sa_mask) != 0) {
    	ABORT("sigfillset() failed");
    }
    if (sigdelset(&act.sa_mask, SIG_RESTART) != 0) {
    	ABORT("sigdelset() failed");
    }
    act.sa_handler = GC_suspend_handler;
    if (sigaction(SIG_SUSPEND, &act, NULL) != 0) {
    	ABORT("Cannot set SIG_SUSPEND handler");
    }

    act.sa_flags = SA_RESTART;
    if (sigfillset(&act.sa_mask) != 0) {
    	ABORT("sigfillset() failed");
    }
    if (sigdelset(&act.sa_mask, SIG_RESTART) != 0) {
    	ABORT("sigdelset() failed");
    }
    act.sa_handler = GC_restart_handler;
    if (sigaction(SIG_RESTART, &act, NULL) != 0) {
    	ABORT("Cannot set SIG_SUSPEND handler");
    }

    /* Add the initial thread, so we can stop it.	*/
      t = GC_new_thread(pthread_self());
      t -> stack_ptr = (ptr_t)(&t);
      t -> flags = DETACHED | MAIN_THREAD;
}

int GC_pthread_sigmask(int how, const sigset_t *set, sigset_t *oset)
{
    sigset_t fudged_set;
    
    if (set != NULL && (how == SIG_BLOCK || how == SIG_SETMASK)) {
        fudged_set = *set;
        sigdelset(&fudged_set, SIG_SUSPEND);
        set = &fudged_set;
    }
    return(pthread_sigmask(how, set, oset));
}

struct start_info {
    void *(*start_routine)(void *);
    void *arg;
};

void GC_thread_exit_proc(void *dummy)
{
    GC_thread me;

    LOCK();
    me = GC_lookup_thread(pthread_self());
    if (me -> flags & DETACHED) {
    	GC_delete_thread(pthread_self());
    } else {
	me -> flags |= FINISHED;
    }
    UNLOCK();
}

int GC_pthread_join(pthread_t thread, void **retval)
{
    int result;
    GC_thread thread_gc_id;
    
    LOCK();
    thread_gc_id = GC_lookup_thread(thread);
    /* This is guaranteed to be the intended one, since the thread id	*/
    /* cant have been recycled by pthreads.				*/
    UNLOCK();
    result = pthread_join(thread, retval);
    LOCK();
    /* Here the pthread thread id may have been recycled. */
    GC_delete_gc_thread(thread, thread_gc_id);
    UNLOCK();
    return result;
}

void * GC_start_routine(void * arg)
{
    struct start_info * si = arg;
    void * result;
    GC_thread me;

    LOCK();
    me = GC_lookup_thread(pthread_self());
    UNLOCK();
    pthread_cleanup_push(GC_thread_exit_proc, 0);
#   ifdef DEBUG_THREADS
        GC_printf1("Starting thread 0x%x\n", pthread_self());
        GC_printf1("pid = %ld\n", (long) getpid());
        GC_printf1("sp = 0x%lx\n", (long) &arg);
#   endif
    result = (*(si -> start_routine))(si -> arg);
#if DEBUG_THREADS
        GC_printf1("Finishing thread 0x%x\n", pthread_self());
#endif
    me -> status = result;
    me -> flags |= FINISHED;
    pthread_cleanup_pop(1);
	/* This involves acquiring the lock, ensuring that we can't exit */
	/* while a collection that thinks we're alive is trying to stop  */
	/* us.								 */
    return(result);
}

int
GC_pthread_create(pthread_t *new_thread,
		  const pthread_attr_t *attr,
                  void *(*start_routine)(void *), void *arg)
{
    int result;
    GC_thread t;
    pthread_t my_new_thread;
    void * stack;
    size_t stacksize;
    pthread_attr_t new_attr;
    int detachstate;
    word my_flags = 0;
    struct start_info * si = GC_malloc(sizeof(struct start_info)); 

    if (0 == si) return(ENOMEM);
    si -> start_routine = start_routine;
    si -> arg = arg;
    LOCK();
    if (!GC_thr_initialized) GC_thr_init();
    if (NULL == attr) {
        stack = 0;
	(void) pthread_attr_init(&new_attr);
    } else {
        new_attr = *attr;
    }
    pthread_attr_getdetachstate(&new_attr, &detachstate);
    if (PTHREAD_CREATE_DETACHED == detachstate) my_flags |= DETACHED;
    result = pthread_create(&my_new_thread, &new_attr, GC_start_routine, si);
    /* No GC can start until the thread is registered, since we hold	*/
    /* the allocation lock.						*/
    if (0 == result) {
        t = GC_new_thread(my_new_thread);
        t -> flags = my_flags;
	t -> stack_ptr = 0;
	t -> stack_end = 0;
        if (0 != new_thread) *new_thread = my_new_thread;
    }
    UNLOCK();  
    /* pthread_attr_destroy(&new_attr); */
    return(result);
}

bool GC_collecting = 0; /* A hint that we're in the collector and       */
                        /* holding the allocation lock for an           */
                        /* extended period.                             */

/* Reasonably fast spin locks.  Basically the same implementation */
/* as STL alloc.h.  This isn't really the right way to do this.   */
/* but until the POSIX scheduling mess gets straightened out ...  */

volatile unsigned int GC_allocate_lock = 0;

void GC_lock()
{
#   define low_spin_max 30  /* spin cycles if we suspect uniprocessor */
#   define high_spin_max 1000 /* spin cycles for multiprocessor */
    static unsigned spin_max = low_spin_max;
    unsigned my_spin_max;
    static unsigned last_spins = 0;
    unsigned my_last_spins;
    unsigned junk;
#   define PAUSE junk *= junk; junk *= junk; junk *= junk; junk *= junk
    int i;

    if (!GC_test_and_set(&GC_allocate_lock)) {
        return;
    }
    my_spin_max = spin_max;
    my_last_spins = last_spins;
    for (i = 0; i < my_spin_max; i++) {
        if (GC_collecting) goto yield;
        if (i < my_last_spins/2 || GC_allocate_lock) {
            PAUSE; 
            continue;
        }
        if (!GC_test_and_set(&GC_allocate_lock)) {
	    /*
             * got it!
             * Spinning worked.  Thus we're probably not being scheduled
             * against the other process with which we were contending.
             * Thus it makes sense to spin longer the next time.
	     */
            last_spins = i;
            spin_max = high_spin_max;
            return;
        }
    }
    /* We are probably being scheduled against the other process.  Sleep. */
    spin_max = low_spin_max;
yield:
    for (;;) {
        if (!GC_test_and_set(&GC_allocate_lock)) {
            return;
        }
        sched_yield();
    }
}

# endif /* LINUX_THREADS */

