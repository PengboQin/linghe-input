package live.linghe.privateinput;

import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** One service's owners. Optional loading must not own transaction completion.
 * The native owner is a single serial lane, but accepted user input is queued
 * ahead of not-started speculative quality/maintenance work. A running native
 * batch is never preempted; only the queue order changes. */
final class ImeTaskExecutors {
 interface Prioritized extends ExecutorService { void executeHigh(Runnable command); void executeSpeculative(Runnable command); }
 private static final AtomicInteger ids=new AtomicInteger();
 final Prioritized nativeWorker;final ExecutorService recent,optional,learning;
 private boolean closed;
 ImeTaskExecutors(){
  int id=ids.incrementAndGet();
  nativeWorker=new PriorityExecutor("Linghe-native-"+id);
  recent=queue("recent",id);optional=queue("optional",id);learning=queue("learning",id);
 }
 private static ExecutorService queue(String role,int id){return Executors.newSingleThreadExecutor(task->new Thread(task,"Linghe-"+role+"-"+id));}
 /** Single serial owner. Priority applies only inside FIFO lifecycle boundaries. */
 private static final class PriorityExecutor extends ThreadPoolExecutor implements Prioritized {
  private long sequence,segment;
  PriorityExecutor(String name){
   super(1,1,0L,TimeUnit.MILLISECONDS,new PriorityBlockingQueue<Runnable>(),
    task->{Thread thread=new Thread(task,name);thread.setDaemon(false);return thread;});
  }
  // Default work is a FIFO boundary: setup, reset, mode changes and teardown
  // may never be crossed by later input. Only explicit speculation is movable.
  @Override public synchronized void execute(Runnable command){
   if(command==null)throw new NullPointerException();
   super.execute(new Task(++segment,0,++sequence,command));segment++;
  }
  @Override public synchronized void executeHigh(Runnable command){enqueue(0,command);}
  @Override public synchronized void executeSpeculative(Runnable command){enqueue(1,command);}
  private void enqueue(int priority,Runnable command){
   if(command==null)throw new NullPointerException();
   super.execute(new Task(segment,priority,++sequence,command));
  }
  private static final class Task implements Runnable,Comparable<Task>{
   final int priority;final long segment,sequence;final Runnable command;
   Task(long segment,int priority,long sequence,Runnable command){this.segment=segment;this.priority=priority;this.sequence=sequence;this.command=command;}
   @Override public void run(){command.run();}
   @Override public int compareTo(Task other){int s=Long.compare(segment,other.segment);if(s!=0)return s;int p=Integer.compare(priority,other.priority);return p!=0?p:Long.compare(sequence,other.sequence);}
  }
 }
 /** Nonblocking for the IME main thread. An accepted native batch can still
  * enqueue its durable finish before the final native cleanup closes learning.
  * Never interrupt or discard prepare/finish: an import may already be durable. */
 synchronized void close(Runnable releaseNative,Runnable finishRecent){
  if(closed)return;closed=true;optional.shutdownNow();
  nativeWorker.execute(()->{try{releaseNative.run();}finally{
   learning.shutdown();
   // Coalesced work may only enqueue its follow-up after this sentinel. Read
   // the last staged selections explicitly before closing that owner.
   recent.execute(()->{try{finishRecent.run();}finally{recent.shutdown();}});
  }});
  nativeWorker.shutdown();
 }
}
