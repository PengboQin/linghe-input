package live.linghe.privateinput;
import java.io.PrintWriter;
/** Fixed numeric diagnostics only. No editor, group, token, text or IO values. */
final class LearningTinyDiagnostics {
 static final class Snapshot {
  final long attempt,applyAttempt;final int stage,startBits,scheduleBits,beginBits,preBits,postBits,leaseReason,failureKind;final boolean closeAttempted,closeOK,applied;
  Snapshot(long attempt,long applyAttempt,int stage,int startBits,int scheduleBits,int beginBits,int preBits,int postBits,int leaseReason,int failureKind,boolean closeAttempted,boolean closeOK,boolean applied){this.attempt=attempt;this.applyAttempt=applyAttempt;this.stage=stage;this.startBits=startBits;this.scheduleBits=scheduleBits;this.beginBits=beginBits;this.preBits=preBits;this.postBits=postBits;this.leaseReason=leaseReason;this.failureKind=failureKind;this.closeAttempted=closeAttempted;this.closeOK=closeOK;this.applied=applied;}
  void print(PrintWriter out){out.println("linghe_learning_diagnostic=1");out.println("attempt="+attempt+" apply_attempt="+applyAttempt+" stage="+stage);out.println("start_bits="+startBits+" schedule_bits="+scheduleBits+" begin_bits="+beginBits);out.println("pre_bits="+preBits+" post_bits="+postBits+" lease_reason="+leaseReason+" failure_kind="+failureKind);out.println("close_attempted="+closeAttempted+" close_ok="+closeOK+" applied="+applied);}
 }
 private volatile Snapshot value=new Snapshot(0,0,0,0,0,0,0,0,0,0,false,false,false);
 Snapshot snapshot(){return value;}
 synchronized void event(int stage,int kind,int bits){Snapshot s=value;value=new Snapshot(s.attempt,s.applyAttempt,stage,kind==1?bits:s.startBits,kind==2?bits:s.scheduleBits,kind==3?bits:s.beginBits,s.preBits,s.postBits,s.leaseReason,s.failureKind,s.closeAttempted,s.closeOK,s.applied);}
 synchronized void began(){Snapshot s=value;value=new Snapshot(s.attempt+1,s.applyAttempt,4,s.startBits,s.scheduleBits,0,s.preBits,s.postBits,s.leaseReason,s.failureKind,s.closeAttempted,s.closeOK,s.applied);}
 synchronized void apply(int pre,int post,int lease,int failure,boolean attempted,boolean closed,boolean applied){Snapshot s=value;value=new Snapshot(s.attempt,s.attempt,7,s.startBits,s.scheduleBits,s.beginBits,pre,post,lease,failure,attempted,closed,applied);}
}
