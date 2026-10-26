package live.linghe.privateinput;
/** Worker-confined, monotonic scheduling. Clipboard polls do not export a fresh
 * learning snapshot; explicit sync and JobScheduler keep the full sync path. */
final class AutomaticSyncCadence {
 static final long CLIPBOARD_DELAY_MS=3000,MAINTENANCE_MS=600000;
 private String binding="";private long maintenanceAt;private boolean started;private int failures;
 // Explicit user controls (undo, pin, reset) publish on the next poll instead of waiting for the 10-minute turn.
 private volatile boolean soon;
 void learningSoon(){soon=true;}
 long pollDelay(boolean success){failures=success?0:Math.min(4,failures+1);return CLIPBOARD_DELAY_MS*(1L<<failures);}
 boolean learningTurn(String scope,long now){
  if(!scope.equals(binding)){binding=scope;started=false;}
  if(soon){soon=false;started=true;maintenanceAt=now;return true;}
  if(!started){started=true;maintenanceAt=now;return false;}
  if(now<maintenanceAt||now-maintenanceAt>=MAINTENANCE_MS){maintenanceAt=now;return true;}
  return false;
 }
}
