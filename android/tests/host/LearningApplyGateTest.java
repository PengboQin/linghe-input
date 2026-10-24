package live.linghe.privateinput;
/** One guard-diagnostic regression; no device, native, IO or weaker predicates. */
public final class LearningApplyGateTest {
 static int n;static void check(boolean b){n++;if(!b)throw new AssertionError("gate check "+n);}
 public static void main(String[]args){
  LearningMaintenanceState m=new LearningMaintenanceState();m.localChanged();m.visible(false,1);LearningMaintenanceState.Ticket a=m.begin(15001,false,false);check(a!=null&&m.applyBlockers(a)==0&&m.mayApply(a));
  m.localChanged();check(m.applyBlockers(a)==8&&!m.mayApply(a));m.finish(a,false);
  LearningMaintenanceState.Ticket b=m.begin(15002,false,false);m.remoteSnapshot("one",true);check(m.applyBlockers(b)==16&&!m.mayApply(b));m.finish(b,false);
  LearningMaintenanceState.Ticket c=m.begin(15003,false,false);m.remoteSnapshot("one",true);check(m.applyBlockers(c)==0);m.visible(true,15004);check(m.applyBlockers(c)==6&&!m.mayApply(c));m.finish(c,false);
  check((m.applyBlockers(c)&1)!=0&&!m.mayApply(c));check((m.applyBlockers(null)&1)!=0&&!m.mayApply(null));
  System.out.println("PASS "+n+" actual apply-guard bit regression; deviceNativeOrUI=false");
 }
}
