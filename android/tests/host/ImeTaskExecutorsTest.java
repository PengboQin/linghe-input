package live.linghe.privateinput;

import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Controlled barriers reproduce optional-loader starvation and destruction
 * during a native import. Only synthetic files; no Android or real user data. */
public final class ImeTaskExecutorsTest {
 private static int checks;
 private static void check(boolean value,String why){if(!value)throw new AssertionError(why);checks++;}
 private static void await(CountDownLatch latch)throws Exception{if(!latch.await(3,TimeUnit.SECONDS))throw new AssertionError("barrier timed out");}
 private static void coalescedFinalSelection()throws Exception{
  ImeTaskExecutors tasks=new ImeTaskExecutors();CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);AtomicInteger staged=new AtomicInteger(),saved=new AtomicInteger();AtomicBoolean first=new AtomicBoolean(true);
  CoalescedWork refresh=new CoalescedWork(tasks.recent,revision->{saved.addAndGet(staged.getAndSet(0));if(first.getAndSet(false)){entered.countDown();try{release.await();}catch(InterruptedException failed){throw new RuntimeException(failed);}}});
  Runnable drain=()->{refresh.close();saved.addAndGet(staged.getAndSet(0));};
  try{
   refresh.request();await(entered);staged.incrementAndGet();refresh.request();
   tasks.close(()->{},drain);check(tasks.nativeWorker.awaitTermination(3,TimeUnit.SECONDS),"final recent drain queued behind in-flight reader");
   release.countDown();check(tasks.recent.awaitTermination(3,TimeUnit.SECONDS),"coalesced recent owner terminates");
   check(saved.get()==1&&staged.get()==0,"last selection saved even when coalesced follow-up queues behind close sentinel");
  }finally{release.countDown();tasks.close(()->{},drain);tasks.nativeWorker.awaitTermination(3,TimeUnit.SECONDS);tasks.recent.awaitTermination(3,TimeUnit.SECONDS);tasks.learning.awaitTermination(3,TimeUnit.SECONDS);tasks.optional.awaitTermination(3,TimeUnit.SECONDS);}
 }
 public static void main(String[] args)throws Exception{
  ImeTaskExecutors tasks=new ImeTaskExecutors();
  CountDownLatch optionalEntered=new CountDownLatch(1),optionalRelease=new CountDownLatch(1),nativeEntered=new CountDownLatch(1),nativeRelease=new CountDownLatch(1),finishEntered=new CountDownLatch(1),finishRelease=new CountDownLatch(1),recentReleased=new CountDownLatch(1);
  AtomicBoolean optionalInterrupted=new AtomicBoolean(),finishInterrupted=new AtomicBoolean();AtomicInteger nativeClosed=new AtomicInteger();
  Path directory=Files.createTempDirectory("linghe-ime-owner-");Path started=directory.resolve("started"),receipt=directory.resolve("receipt");
  try{
   tasks.optional.execute(()->{optionalEntered.countDown();try{optionalRelease.await();}catch(InterruptedException expected){optionalInterrupted.set(true);}});
   await(optionalEntered);
   check(tasks.learning.submit(()->"ready").get(1,TimeUnit.SECONDS).equals("ready"),"blocked optional model cannot starve maintenance completion");
   tasks.nativeWorker.execute(()->{try{
    Files.write(started,Collections.singletonList("synthetic-imported"));nativeEntered.countDown();nativeRelease.await();
    tasks.learning.execute(()->{try{finishEntered.countDown();finishRelease.await();Files.write(receipt,Collections.singletonList("synthetic-completed"));Files.delete(started);}catch(InterruptedException failed){finishInterrupted.set(true);}catch(Exception failed){throw new RuntimeException(failed);}});
   }catch(Exception failed){throw new RuntimeException(failed);}});
   await(nativeEntered);
   FutureTask<Void> close=new FutureTask<>(()->{tasks.close(()->{nativeClosed.incrementAndGet();tasks.recent.execute(recentReleased::countDown);},()->{});return null;});
   Thread main=new Thread(close,"fixture-main");main.start();close.get(1,TimeUnit.SECONDS);
   check(Files.exists(started)&&!Files.exists(receipt),"close returns while accepted native batch is still active");
   check(nativeClosed.get()==0,"close does not destroy active native owner");
   boolean rejected=false;try{tasks.nativeWorker.execute(()->{});}catch(RejectedExecutionException expected){rejected=true;}check(rejected,"destroyed service rejects new native input");
   nativeRelease.countDown();await(finishEntered);await(recentReleased);
   check(nativeClosed.get()==1,"native cleanup follows accepted batch once");
   check(!tasks.learning.isTerminated(),"running durable finish retained across close");
   finishRelease.countDown();check(tasks.learning.awaitTermination(3,TimeUnit.SECONDS),"learning owner drains and releases");
   check(Files.exists(receipt)&&!Files.exists(started)&&!finishInterrupted.get(),"accepted import reaches receipt without forced interruption");
   check(tasks.nativeWorker.awaitTermination(3,TimeUnit.SECONDS)&&tasks.recent.awaitTermination(3,TimeUnit.SECONDS)&&tasks.optional.awaitTermination(3,TimeUnit.SECONDS),"all service executors terminate");
   check(optionalInterrupted.get(),"optional loading is cancelled independently");
   tasks.close(()->nativeClosed.incrementAndGet(),()->{});check(nativeClosed.get()==1,"duplicate close does not release native twice");
   coalescedFinalSelection();
   System.out.println("PASS assertions="+checks+" optionalIsolation=true nativeFinishDrained=true mainNonblocking=true syntheticFilesOnly=true");
  }finally{
   optionalRelease.countDown();nativeRelease.countDown();finishRelease.countDown();tasks.close(()->{},()->{});
   tasks.nativeWorker.awaitTermination(3,TimeUnit.SECONDS);tasks.learning.awaitTermination(3,TimeUnit.SECONDS);tasks.recent.awaitTermination(3,TimeUnit.SECONDS);tasks.optional.awaitTermination(3,TimeUnit.SECONDS);
   Files.deleteIfExists(started);Files.deleteIfExists(receipt);Files.deleteIfExists(directory);
  }
 }
}
