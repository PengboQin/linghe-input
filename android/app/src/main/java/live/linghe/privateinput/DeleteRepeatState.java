package live.linghe.privateinput;
/** Old delayed callbacks cannot delete after release, detach or a new press. */
final class DeleteRepeatState {
 static final long DELAY_MS=400,INTERVAL_MS=65;
 private long generation;private boolean held;
 long begin(){held=true;return ++generation;}
 boolean current(long token){return held&&generation==token;}
 boolean move(float x,float y,int width,int height,int slop){if(held&&(x < -slop||y < -slop||x>=width+slop||y>=height+slop)){cancel();return true;}return false;}
 void cancel(){held=false;++generation;}
}
