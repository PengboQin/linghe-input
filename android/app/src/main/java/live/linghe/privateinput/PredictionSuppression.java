package live.linghe.privateinput;
/** Explicit clear cancels candidate publication; explicit input actions retain their FIFO. */
final class PredictionSuppression {
 private volatile boolean suppressed;private final java.util.concurrent.atomic.AtomicLong cancellation=new java.util.concurrent.atomic.AtomicLong(),lifetime=new java.util.concurrent.atomic.AtomicLong();
 boolean suppressed(){return suppressed;}
 static boolean canClear(boolean composition,int queued,boolean auxiliary){return composition||queued>0||auxiliary;}
 void deleting(){suppressed=true;}
 static final class ClearPlan{final boolean invalidateOwnCommit,inspectNative;ClearPlan(boolean composition,int queued){invalidateOwnCommit=composition;inspectNative=composition||queued>0;}}
 ClearPlan clearComposition(boolean composition,int queued){suppressed=true;cancellation.incrementAndGet();return new ClearPlan(composition,queued);}
 void clearComposition(){clearComposition(false,0);}
 void explicitInput(){suppressed=false;}
 void newDocument(){lifetime.incrementAndGet();suppressed=false;cancellation.incrementAndGet();}
 long inputLifetime(){return lifetime.get();}
 boolean active(long expected){return lifetime.get()==expected;}
 long cancellation(){return cancellation.get();}
 boolean current(long expected){return cancellation.get()==expected;}
}
