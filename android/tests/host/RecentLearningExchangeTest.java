package live.linghe.privateinput;
import java.util.*;
public final class RecentLearningExchangeTest {
 static int checks;static void ok(boolean value,String reason){++checks;if(!value)throw new AssertionError(reason);}
 interface Work{void run()throws Exception;}static void rejects(Work work,String label)throws Exception{boolean rejected=false;try{work.run();}catch(Exception expected){rejected=true;}ok(rejected,label);}
 public static void main(String[]args)throws Exception{
  String own="11111111-2222-3333-4444-555555555555",peer="22222222-2222-3333-4444-555555555555",event="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",newer="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee";
  RecentLearningExchangeState state=new RecentLearningExchangeState("group/1/2/server");
  ok(state.due(0,"boot"),"first attempt immediate");state.attempted(0,"boot");
  ok(!state.due(0,"boot")&&!state.due(29999,"boot"),"failed requests wait 30s");ok(!state.due(29999,"boot",true),"manual action cannot bypass failure backoff");ok(state.due(30000,"boot"),"failure retry due at 30s");
  state.succeeded(30000,"boot");ok(!state.due(30001,"boot")&&!state.due(629999,"boot"),"success cools down 10min");ok(state.due(630000,"boot"),"success expires at 10min");ok(state.due(30001,"boot",true),"explicit sync remains immediate after success");ok(state.due(1,"new-boot"),"reboot does not inherit old monotonic delay");ok(state.due(10,"boot"),"monotonic reset has bounded recovery");ok(!state.due(-1,"boot")&&!state.due(1,""),"invalid monotonic clock rejected");
  state.conditional=true;rejects(()->state.merged(peer,event,()->{throw new Exception("disk full");}),"failed durable merge propagated");ok(state.knownEvent(peer)==null,"receive alone never advances known event");
  final boolean[] durable={false};state.merged(peer,event,()->{ok(state.knownEvent(peer)==null,"hint absent during merge");durable[0]=true;});ok(durable[0]&&state.knownEvent(peer).equals(event.toUpperCase(Locale.ROOT)),"hint appears after successful durable merge");
  rejects(()->state.merged(peer,newer,()->{throw new Exception("projection failed");}),"projection failure propagated");ok(state.knownEvent(peer).equals(event.toUpperCase(Locale.ROOT)),"partial merge retains old known event");
  state.conditional=false;ok(state.knownEvent(peer)==null,"old server has no skip hints");state.conditional=true;
  RecentLearningExchangeState restored=new RecentLearningExchangeState(state.binding);restored.restoreKnown(state.known);restored.conditional=true;ok(restored.knownEvent(peer).equals(state.knownEvent(peer)),"persisted known IDs restore without body copies");
  RecentLearningExchangeState rotated=new RecentLearningExchangeState("group/2/3/server");rotated.conditional=true;ok(rotated.knownEvent(peer)==null&&rotated.due(1,"boot"),"epoch or server context starts empty");
  rejects(()->restored.restoreKnown(Collections.singletonMap("bad",event)),"malformed sender rejected");rejects(()->restored.restoreKnown(Collections.singletonMap(own,"bad")),"malformed event rejected");
  Map<String,String> tooMany=new HashMap<>();for(int i=0;i<65;i++)tooMany.put(String.format(Locale.ROOT,"%08x-2222-3333-4444-555555555555",i),event);rejects(()->restored.restoreKnown(tooMany),"known sender count bounded");
  RecentLearningSlot conditional=new RecentLearningSlot(event,null,own,null,event);ok(conditional.publishedEvent.equals(event.toUpperCase(Locale.ROOT)),"known own slot can omit full envelope");
  rejects(()->new RecentLearningSlot(event,null,own,null,newer),"different known event cannot authorize omitted envelope");rejects(()->new RecentLearningSlot(event,null,own,null),"legacy constructor still requires full envelope");rejects(()->new RecentLearningSlot(event,event,own,peer,event),"conditional hint cannot waive actual sender validation");
  ok(!conditional.shouldPush("same","same",100,101),"skip download does not trigger fresh upload");ok(conditional.shouldPush("new","same",100,101),"local changes still publish");
  System.out.println("PASS "+checks+" Android conditional snapshot and monotonic cadence checks; network=false");
 }
}
