package live.linghe.privateinput;
/** One native owner at a time. Failure is recoverable; timeout never starts a
 * second native initialization over the first one. No Android or IO dependency. */
final class EngineStartupState {
 static final long RETRY_DELAY_MS=2000, SLOW_MS=3000;
 private long serial,started,finished;private boolean running,available,closed;private String phase="idle",failure="";
 synchronized long begin(long now,boolean explicit){if(closed||running||available||!explicit&&finished>0&&now-finished<RETRY_DELAY_MS)return 0;running=true;started=now;phase="privacy";failure="";return ++serial;}
 synchronized boolean current(long owner){return !closed&&owner!=0&&owner==serial;}
 synchronized boolean phase(long owner,String next){if(!current(owner)||!running)return false;phase=next;return true;}
 synchronized boolean success(long owner,long now){if(!current(owner)||!running)return false;running=false;available=true;finished=now;phase="ready";return true;}
 synchronized boolean fail(long owner,long now,String kind){if(!current(owner))return false;running=false;available=false;finished=now;phase="failed";failure=kind;return true;}
 synchronized void unavailable(long now,String kind){if(closed)return;running=false;available=false;finished=now;phase="failed";failure=kind;++serial;}
 synchronized void close(){closed=true;running=false;available=false;phase="closed";++serial;}
 synchronized long owner(){return serial;}
 synchronized String phase(){return phase;}
 synchronized String failure(){return failure;}
 synchronized boolean failed(){return !closed&&!running&&!available&&phase.equals("failed");}
 synchronized boolean slow(long now){return running&&now-started>=SLOW_MS;}
 synchronized boolean running(){return running;}
}
