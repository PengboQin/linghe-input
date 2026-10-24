package live.linghe.privateinput;
/** Actual maintenance owner; synthetic callback order, no device or native claims. */
public final class LearningInputVisibilityTest {
 static int checks;static void check(boolean value){checks++;if(!value)throw new AssertionError("visibility "+checks);}
 public static void main(String[] args){
  LearningMaintenanceState state=new LearningMaintenanceState();
  state.visible(true,100);state.localChanged();
  state.visible(false,200); // onFinishInputView; onWindowHidden need not follow.
  state.inputStarted(false,300); // Main page editor bound while input view stays hidden.
  check(state.diagnosticBits()==2);check(state.delay(300)==14900);
  LearningMaintenanceState.Ticket plan=state.begin(15200,false,false);
  check(plan!=null&&state.mayApply(plan));
  state.visible(true,15201); // onWindowShown immediately revokes prepared native apply.
  check(!state.mayApply(plan));check(state.delay(15201)==-1);
  state.finish(plan,false);state.inputStarted(true,15202);
  check((state.diagnosticBits()&1)==1);check(state.delay(15202)==-1);
  System.out.println("PASS "+checks+" hidden-editor/finish/show owner checks; nativeOrUI=false");
 }
}
