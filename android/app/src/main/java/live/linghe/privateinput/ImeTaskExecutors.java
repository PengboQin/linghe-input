package live.linghe.privateinput;

import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** One service's owners. Optional loading must not own transaction completion. */
final class ImeTaskExecutors {
 private static final AtomicInteger ids=new AtomicInteger();
 final ExecutorService nativeWorker,recent,optional,learning;
 private boolean closed;
 ImeTaskExecutors(){int id=ids.incrementAndGet();nativeWorker=queue("native",id);recent=queue("recent",id);optional=queue("optional",id);learning=queue("learning",id);}
 private static ExecutorService queue(String role,int id){return Executors.newSingleThreadExecutor(task->new Thread(task,"Linghe-"+role+"-"+id));}
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
