package live.linghe.privateinput;
public final class RecentCompatibilityCadenceTest {
 static int checks;static void ok(boolean b,String name){checks++;if(!b)throw new AssertionError(name);}
 public static void main(String[]a){
  long day=RecentCompatibilityCadence.DAY_MS,wall=1800000000000L,up=900000;RecentCompatibilityCadence clock=new RecentCompatibilityCadence("group/epoch/install");ok(clock.due(wall,up,"boot"),"first full compatibility due");clock.succeeded(wall,up,"boot");ok(!clock.due(wall+600000,up+600000,"boot"),"ten minute cloud maintenance does not make compatibility due");ok(!clock.due(wall+day-1,up+day-1,"boot"),"just before full day");ok(clock.due(wall+day,up+day,"boot"),"full day boundary");ok(!clock.due(wall+10*day,up+1,"boot"),"same boot wall forward does not amplify full transfer");ok(!clock.due(wall-day,up+600000,"boot"),"same boot wall rollback follows monotonic");
  RecentCompatibilityCadence reopened=new RecentCompatibilityCadence(clock.binding);reopened.successWall=clock.successWall;reopened.successUptime=clock.successUptime;reopened.successBoot=clock.successBoot;ok(!reopened.due(wall+1000,up+1000,"boot"),"process restart keeps daily timer");ok(!reopened.due(wall+600000,1000,"newboot"),"device reboot keeps bounded wall timer");ok(reopened.due(wall+day,1000,"newboot"),"reboot daily boundary");ok(reopened.due(wall-1,1000,"newboot"),"reboot wall rollback safely repairs");ok(new RecentCompatibilityCadence("newscope").due(wall,up,"boot"),"new group epoch installation independent");
  RecentLearningExchangeState legacy=new RecentLearningExchangeState("legacy");legacy.succeeded(up,"boot");ok(!legacy.due(up+599999,"boot")&&legacy.due(up+600000,"boot"),"disabled cloud immediately uses original 600 seconds");legacy.attempted(up+600000,"boot");ok(!legacy.due(up+629999,"boot",true)&&legacy.due(up+630000,"boot",true),"existing failure backoff stays 30 seconds");
  // Failed compatibility attempts never call succeeded; cloud clocks are separate.
  long before=clock.successWall;for(int i=1;i<=12;i++)legacy.succeeded(up+i*600000,"boot");ok(clock.successWall==before&&clock.due(wall+day,up+day,"boot"),"cloud success cannot postpone independent daily repair");
  System.out.println("PASS "+checks+" compatibility day/reboot/scope/backoff clocks; network=false");
 }
}
