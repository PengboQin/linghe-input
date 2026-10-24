package live.linghe.privateinput;
/** Small clock/revision checks for the actual maintenance policy, no native/UI. */
public final class LearningShortPolicyTest {
 static int n;static void ok(boolean b){n++;if(!b)throw new AssertionError("policy check "+n);}
 public static void main(String[]args){
  LearningMaintenanceState state=new LearningMaintenanceState();state.localChanged();state.visible(false,1000);LearningMaintenanceState.Ticket one=state.begin(16000,false,false);ok(one!=null&&state.mayApply(one));
  state.localChanged();ok(!state.mayApply(one));state.finish(one,false,16001);ok(state.dirty()&&state.delay(16001)==15000);ok(state.begin(31000,false,false)==null);
  LearningMaintenanceState.Ticket two=state.begin(31001,false,false);ok(two!=null&&state.mayApply(two));state.remoteSnapshot("new",true);ok(!state.mayApply(two));state.finish(two,false,31002);ok(state.delay(31002)==15000);
  LearningMaintenanceState.Ticket three=state.begin(46002,false,false);ok(three!=null&&state.mayApply(three));state.visible(true,46003);ok(!state.mayApply(three));state.finish(three,false,46003);ok(state.delay(50000)==-1);
  state.reset(false,60000);ok(!state.dirty());state.localChanged();ok(state.begin(76000,false,false)!=null);
  System.out.println("PASS "+n+" actual maintenance revision/visibility/failure-cooldown checks; nativeOrUI=false");
 }
}
