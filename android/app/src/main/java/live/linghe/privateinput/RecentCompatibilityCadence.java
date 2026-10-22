package live.linghe.privateinput;
/** Independent successful full-v2 compatibility clock. Cloud/clipboard passes
 * never advance it. Same-boot monotonic time wins; restart uses persisted wall
 * time, clock rollback forces a safe compatibility repair. */
final class RecentCompatibilityCadence {
 static final long DAY_MS=24*60*60*1000L;
 final String binding;long successWall=-1,successUptime=-1;String successBoot="";
 RecentCompatibilityCadence(String binding){this.binding=binding;}
 boolean due(long wall,long uptime,String boot){
  if(wall<0||uptime<0||boot==null||boot.isEmpty())return true;
  if(successWall<0||successUptime<0||successBoot.isEmpty())return true;
  if(successBoot.equals(boot)&&uptime>=successUptime)return uptime-successUptime>=DAY_MS;
  return wall<successWall||wall-successWall>=DAY_MS;
 }
 void succeeded(long wall,long uptime,String boot){successWall=wall;successUptime=uptime;successBoot=boot;}
}
