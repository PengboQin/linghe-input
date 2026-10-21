package live.linghe.privateinput;
import java.util.concurrent.*;import java.util.concurrent.atomic.*;
/** One queued/running job and at most one follow-up, on the supplied IO executor. */
final class CoalescedWork implements Runnable {
 interface Work{void run(long revision);}
 private final Executor executor;private final Work work;private final AtomicLong revision=new AtomicLong();private final AtomicBoolean scheduled=new AtomicBoolean();private volatile boolean closed;
 CoalescedWork(Executor executor,Work work){this.executor=executor;this.work=work;}
 void request(){if(closed)return;revision.incrementAndGet();schedule();}
 boolean current(long expected){return !closed&&revision.get()==expected;}
 void close(){closed=true;revision.incrementAndGet();}
 private void schedule(){if(closed||!scheduled.compareAndSet(false,true))return;try{executor.execute(this);}catch(RejectedExecutionException ended){scheduled.set(false);}}
 public void run(){long start=revision.get();try{if(!closed)work.run(start);}finally{scheduled.set(false);if(!closed&&start!=revision.get())schedule();}}
}
