package live.linghe.privateinput;
import java.util.*;
import java.nio.charset.StandardCharsets;

/** Volatile derived state only; restart drains the relay before auto-apply. */
final class AutoClipboardState {
 static final class Pass {final String scope;final long localGeneration;final boolean outgoing;Pass(String s,long g,boolean outgoing){scope=s;localGeneration=g;this.outgoing=outgoing;}}
 static final class Copy {final String version,text;Copy(String v,String t){version=v;text=t;}}
 private String scope="",lastVersion="";private long localGeneration;private boolean baseline,armed,blockedLocalClipboard;
 private Copy pending;private final LinkedHashSet<String> seen=new LinkedHashSet<>();
 synchronized void reset(String scope){this.scope=scope;lastVersion="";localGeneration++;baseline=false;armed=false;blockedLocalClipboard=false;pending=null;seen.clear();}
 synchronized Pass begin(String next){return begin(next,false);}
 synchronized Pass begin(String next,boolean outgoing){if(!scope.equals(next)){String version=lastVersion;boolean observed=baseline,blocked=blockedLocalClipboard;Copy newlyObserved=scope.isEmpty()?pending:null;reset(next);if(!next.isEmpty()){lastVersion=version;baseline=observed;blockedLocalClipboard=blocked;pending=newlyObserved;}}return new Pass(scope,localGeneration,outgoing);}
 /** Only an affirmative, readable empty-board observation may call this.
  * Existing user clear/sensitive protection is never released by re-observation. */
 synchronized void establishEmptyBaseline(String version){if(!baseline){lastVersion=version;baseline=true;blockedLocalClipboard=false;}}
 synchronized void observe(String version,String text,boolean owned){
  if(version.equals(lastVersion))return;lastVersion=version;
  if(!baseline){baseline=true;blockedLocalClipboard=!owned&&!eligible(text);return;}
  if(owned)return;
  localGeneration++;blockedLocalClipboard=!eligible(text);pending=eligible(text)?new Copy(version,text):null;
 }
 synchronized Copy pending(){return pending;}
 synchronized void queued(Copy copy){if(pending!=null&&pending.version.equals(copy.version)&&pending.text.equals(copy.text))pending=null;}
 synchronized boolean accept(Pass pass,String event,boolean expired,boolean ownSender){
  if(!scope.equals(pass.scope)||scope.isEmpty()||seen.contains(event))return false;
  seen.add(event);while(seen.size()>256)seen.remove(seen.iterator().next());
  return armed&&!expired&&!ownSender&&!pass.outgoing&&!blockedLocalClipboard&&pending==null&&localGeneration==pass.localGeneration;
 }
 synchronized void drained(Pass pass){if(scope.equals(pass.scope)&&!scope.isEmpty())armed=true;}
 synchronized boolean current(Pass pass){return scope.equals(pass.scope)&&!scope.isEmpty();}
 static boolean eligible(String text){return text!=null&&!text.isEmpty()&&text.length()<=65536&&text.indexOf('\0')<0&&text.getBytes(StandardCharsets.UTF_8).length<=65536;}
}
