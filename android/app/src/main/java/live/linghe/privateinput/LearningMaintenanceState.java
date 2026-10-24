package live.linghe.privateinput;
/** Hidden snapshot/apply lease; pure IO is cancellable, native batches stay serial. */
final class LearningMaintenanceState {
 static final long HIDDEN_COOLDOWN_MS=15000;
 static final class Ticket{final long local,remote,visibility;final boolean cold;Ticket(long l,long r,long v,boolean c){local=l;remote=r;visibility=v;cold=c;}}
 private boolean visible=true,localDirty,remoteDirty;private long hiddenAt,visibility,localRevision,remoteRevision,retryAt;private String remoteToken="";private Ticket running;
 synchronized void reset(boolean next,long now){visible=next;hiddenAt=now;visibility++;localDirty=false;remoteDirty=false;remoteToken="";running=null;retryAt=0;}
 synchronized void visible(boolean next,long now){if(next==visible)return;visible=next;visibility++;if(!next)hiddenAt=now;}
 /** A bound editor can exist without an onscreen keyboard. */
 synchronized void inputStarted(boolean inputViewShown,long now){visible(inputViewShown,now);}
 synchronized void localChanged(){localDirty=true;localRevision++;}
 synchronized void remoteSnapshot(String token,boolean changed){if(changed){if(!remoteDirty||!remoteToken.equals(token)){remoteDirty=true;remoteRevision++;}}else remoteDirty=false;remoteToken=token;}
 synchronized boolean localPending(){return localDirty;}
 synchronized boolean dirty(){return localDirty||remoteDirty;}
 synchronized int diagnosticBits(){return (visible?1:0)|(localDirty?2:0)|(remoteDirty?4:0)|(running!=null?8:0);}
 synchronized long delay(long now){return visible||!dirty()||running!=null?-1:Math.max(Math.max(0,HIDDEN_COOLDOWN_MS-Math.max(0,now-hiddenAt)),Math.max(0,retryAt-now));}
 synchronized Ticket begin(long now,boolean cold,boolean nativePending){if(running!=null||nativePending||!cold&&(visible||!dirty()||delay(now)>0))return null;return running=new Ticket(localRevision,remoteRevision,visibility,cold);}
 synchronized boolean mayStart(Ticket ticket){return ticket==running&&(ticket.cold||!visible&&ticket.visibility==visibility);}
 /** Fixed diagnostics only: no identity, token or revision values leave this owner. */
 synchronized int applyBlockers(Ticket ticket){int bits=0;if(ticket==null||ticket!=running)bits|=1;if(visible)bits|=2;if(ticket!=null){if(ticket.visibility!=visibility)bits|=4;if(ticket.local!=localRevision)bits|=8;if(ticket.remote!=remoteRevision)bits|=16;}return bits;}
 synchronized boolean mayApply(Ticket ticket){return applyBlockers(ticket)==0;}
 synchronized void finish(Ticket ticket,boolean success){finish(ticket,success,0);}
 synchronized void finish(Ticket ticket,boolean success,long now){if(ticket!=running)return;if(success){if(localRevision==ticket.local)localDirty=false;if(remoteRevision==ticket.remote)remoteDirty=false;retryAt=0;}else if(now>0)retryAt=now+HIDDEN_COOLDOWN_MS;running=null;}
}
