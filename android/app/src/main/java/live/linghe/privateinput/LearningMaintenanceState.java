package live.linghe.privateinput;
/** Native checkpoints are non-interruptible: enter only after stable hidden time. */
final class LearningMaintenanceState {
 static final long HIDDEN_COOLDOWN_MS=15000;
 static final class Ticket{final long local,remote,visibility;final boolean cold;Ticket(long l,long r,long v,boolean c){local=l;remote=r;visibility=v;cold=c;}}
 private boolean visible=true,localDirty,remoteDirty;private long hiddenAt,visibility,localRevision,remoteRevision;private String remoteToken="";private Ticket running;
 synchronized void reset(boolean next,long now){visible=next;hiddenAt=now;visibility++;localDirty=false;remoteDirty=false;remoteToken="";running=null;}
 synchronized void visible(boolean next,long now){if(next==visible)return;visible=next;visibility++;if(!next)hiddenAt=now;}
 synchronized void localChanged(){localDirty=true;localRevision++;}
 synchronized void remoteSnapshot(String token,boolean changed){if(changed){if(!remoteDirty||!remoteToken.equals(token)){remoteDirty=true;remoteRevision++;}}else remoteDirty=false;remoteToken=token;}
 synchronized boolean localPending(){return localDirty;}
 synchronized boolean dirty(){return localDirty||remoteDirty;}
 synchronized long delay(long now){return visible||!dirty()||running!=null?-1:Math.max(0,HIDDEN_COOLDOWN_MS-Math.max(0,now-hiddenAt));}
 synchronized Ticket begin(long now,boolean cold,boolean nativePending){if(running!=null||nativePending||!cold&&(visible||!dirty()||delay(now)>0))return null;return running=new Ticket(localRevision,remoteRevision,visibility,cold);}
 synchronized boolean mayStart(Ticket ticket){return ticket==running&&(ticket.cold||!visible&&ticket.visibility==visibility);}
 synchronized void finish(Ticket ticket,boolean success){if(ticket!=running)return;if(success){if(localRevision==ticket.local)localDirty=false;if(remoteRevision==ticket.remote)remoteDirty=false;}running=null;}
}
