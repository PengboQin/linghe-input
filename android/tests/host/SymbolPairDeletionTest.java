package live.linghe.privateinput;

import android.view.inputmethod.*;
import java.lang.reflect.*;
import java.util.*;

/** Product tracker + native InputConnection adapter on a deterministic host. */
public final class SymbolPairDeletionTest {
 static int checks;
 static void ok(boolean value,String label){checks++;if(!value)throw new AssertionError(label);}
 static final class Host implements InvocationHandler {
  String text;int start,end,deleteCalls,beforeDelete,afterDelete,extractCalls;boolean unavailable,partial,reject,mutateOnReject,ignoreCommit,throwBatch,throwSelection,throwDelete;Runnable onRead;
  final InputConnection connection=(InputConnection)Proxy.newProxyInstance(InputConnection.class.getClassLoader(),new Class<?>[]{InputConnection.class},this);
  Host(String before,String after){text=before+after;start=end=before.length();}
  public Object invoke(Object proxy,Method method,Object[] args){
   String name=method.getName();
   if(name.equals("getExtractedText")){
    extractCalls++;if(onRead!=null){Runnable callback=onRead;onRead=null;callback.run();}
    if(unavailable)return null;
    ExtractedTextRequest request=(ExtractedTextRequest)args[0];ok(request.hintMaxChars<=132&&(Integer)args[1]==0,"bounded read, no monitor");
    ExtractedText value=new ExtractedText();value.text=text;value.startOffset=0;value.selectionStart=start;value.selectionEnd=end;value.partialStartOffset=partial?0:-1;value.partialEndOffset=-1;return value;
   }
   if(name.equals("commitText")){if(ignoreCommit)return true;String value=args[0].toString();text=text.substring(0,start)+value+text.substring(end);start+=value.length();end=start;return true;}
   if(name.equals("beginBatchEdit")||name.equals("endBatchEdit")){if(throwBatch)throw new IllegalStateException("unsupported batch");return true;}
   if(name.equals("setSelection")){if(throwSelection)throw new IllegalStateException("unsupported selection");start=(Integer)args[0];end=(Integer)args[1];return true;}
   if(name.equals("deleteSurroundingTextInCodePoints")){
    deleteCalls++;if(throwDelete)throw new IllegalStateException("uncertain delete");beforeDelete=(Integer)args[0];afterDelete=(Integer)args[1];
    if(!reject||mutateOnReject){int a=Character.offsetByCodePoints(text,start,-(mutateOnReject?1:beforeDelete)),b=Character.offsetByCodePoints(text,end,mutateOnReject?0:afterDelete);text=text.substring(0,a)+text.substring(b);start=end=a;}return !reject;
   }
   if(name.equals("toString"))return "SyntheticPairHost";
   Class<?> type=method.getReturnType();return type==boolean.class?false:type==int.class?0:null;
  }
 }
 static final class Prepared {final SymbolPairing.Intent intent;final SymbolPairing.Insertion insertion;Prepared(SymbolPairing.Intent intent,SymbolPairing.Insertion insertion){this.intent=intent;this.insertion=insertion;}}
 static Prepared insert(Host host,SymbolPairing.Tracker tracker,boolean inside,String symbol,String prefix){
  SymbolPairing.Plan plan=SymbolPairing.plan(symbol,true,inside);SymbolPairing.Intent intent=tracker.intent(7,host.connection,plan);intent.appended=true;
  SymbolPairing.Insertion insertion=tracker.beforeCommit(intent,7,host.connection,prefix+plan.insertedText,SymbolPairInputConnection.read(host.connection),false);
  host.connection.commitText(prefix+plan.insertedText,1);if(plan.caretBack>0)host.connection.setSelection(host.start-plan.caretBack,host.end-plan.caretBack);
  tracker.committed(insertion,SymbolPairInputConnection.read(host.connection));return new Prepared(intent,insertion);
 }
 static boolean erase(Host host,SymbolPairing.Tracker tracker){return SymbolPairInputConnection.erase(tracker,host.connection,7,true,()->true);}
 public static void main(String[] args){
  for(String symbol:new String[]{"(","（","[","【","{","《","〈","「","『","“","‘","\""})for(boolean inside:new boolean[]{false,true}){
   Host host=new Host("😀前","后文");SymbolPairing.Tracker tracker=new SymbolPairing.Tracker();insert(host,tracker,inside,symbol,"");ok(tracker.hasReceipt(),"own pair armed "+symbol+inside);ok(erase(host,tracker),"handled own pair");ok(host.text.equals("😀前后文")&&host.start==3,"only generated pair removed");ok(host.beforeDelete==(inside?1:2)&&host.afterDelete==(inside?1:0),"native codepoint ranges");ok(!erase(host,tracker)&&host.deleteCalls==1,"one receipt, one delete");
  }
  Host host=new Host("已选","");SymbolPairing.Tracker tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","词语");ok(erase(host,tracker)&&host.text.equals("已选词语"),"accepted Chinese prefix survives");
  for(String manual:new String[]{"()","（）","\"\""}){host=new Host(manual,"");tracker=new SymbolPairing.Tracker();ok(!erase(host,tracker)&&host.deleteCalls==0&&host.extractCalls==0,"manual/pasted adjacent pair never grants receipt");}
  host=new Host("","");tracker=new SymbolPairing.Tracker();SymbolPairing.Plan disabled=SymbolPairing.plan("(",false,true);SymbolPairing.Intent intent=tracker.intent(7,host.connection,disabled);intent.appended=true;ok(tracker.beforeCommit(intent,7,host.connection,"(",SymbolPairInputConnection.read(host.connection),false)==null,"autoPair off cannot arm");
  host=new Host("a","b");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");ok(!SymbolPairInputConnection.erase(tracker,host.connection,7,false,()->true)&&!tracker.hasReceipt()&&host.deleteCalls==0,"setting disabled after insertion");
  host=new Host("","");tracker=new SymbolPairing.Tracker();Prepared prepared=insert(host,tracker,true,"(","");tracker.invalidate();tracker.committed(prepared.insertion,SymbolPairInputConnection.read(host.connection));ok(!erase(host,tracker),"explicit edit cancels old and late arm");
  host=new Host("","");tracker=new SymbolPairing.Tracker();intent=tracker.intent(7,host.connection,SymbolPairing.plan("(",true,true));intent.appended=true;
  SymbolPairing.Insertion flight=tracker.beforeCommit(intent,7,host.connection,"()",SymbolPairInputConnection.read(host.connection),false);host.connection.commitText("()",1);tracker.selectionChanged(0,0,2,2);host.connection.setSelection(1,1);tracker.selectionChanged(2,2,1,1);tracker.committed(flight,SymbolPairInputConnection.read(host.connection));tracker.selectionChanged(0,0,1,1);ok(erase(host,tracker),"own in-flight and final coalesced selection acknowledgements remain eligible");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");tracker.selectionChanged(0,0,2,2);ok(!erase(host,tracker),"late intermediate selection is conservatively rejected");
  host=new Host("a","b");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");int saved=host.start;tracker.selectionChanged(saved,saved,saved+1,saved+1);tracker.selectionChanged(saved+1,saved+1,saved,saved);ok(!erase(host,tracker),"cursor moved away and back does not revive");
  host=new Host("a","b");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");tracker.selectionChanged(host.start,host.end,host.start-1,host.end);ok(!erase(host,tracker),"selected range invalidates");
  for(boolean left:new boolean[]{false,true}){host=new Host("abc","xyz");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");host.text=left?"z"+host.text.substring(1):host.text.substring(0,host.text.length()-1)+"q";ok(!erase(host,tracker)&&host.deleteCalls==0,"edited local context does not delete pair");}
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");host.text="(x)";host.start=host.end=2;ok(!erase(host,tracker),"pair no longer empty");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");ok(!SymbolPairInputConnection.erase(tracker,host.connection,8,true,()->true)&&host.deleteCalls==0,"editor document switched");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");Host other=new Host("(",")");ok(!SymbolPairInputConnection.erase(tracker,other.connection,7,true,()->true)&&other.deleteCalls==0,"different InputConnection cannot reuse receipt");
  for(boolean partial:new boolean[]{false,true}){host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");host.partial=partial;host.unavailable=!partial;ok(!erase(host,tracker)&&host.deleteCalls==0,"missing/partial readback fails closed");}
  host=new Host("","");tracker=new SymbolPairing.Tracker();host.ignoreCommit=true;prepared=insert(host,tracker,false,"(","");ok(!tracker.hasReceipt(),"accepted API request but missing actual inserted output");
  host=new Host("","");tracker=new SymbolPairing.Tracker();intent=tracker.intent(7,host.connection,SymbolPairing.plan("(",true,true));intent.appended=true;ok(tracker.beforeCommit(intent,7,host.connection,"()",SymbolPairInputConnection.read(host.connection),true)==null,"unknown active composing replacement range");
  host=new Host("","");tracker=new SymbolPairing.Tracker();intent=tracker.intent(7,host.connection,SymbolPairing.plan("(",true,true));ok(tracker.beforeCommit(intent,7,host.connection,"()",SymbolPairInputConnection.read(host.connection),false)==null,"suffix coincidence without actual append not provenance");
  host=new Host("","");tracker=new SymbolPairing.Tracker();intent=tracker.intent(7,host.connection,SymbolPairing.plan("(",true,true));intent.appended=true;tracker.selectionChanged(0,0,1,1);ok(tracker.beforeCommit(intent,7,host.connection,"()",SymbolPairInputConnection.read(host.connection),false)==null,"cursor movement while async symbol queued fences receipt");
  host=new Host("","");tracker=new SymbolPairing.Tracker();prepared=insert(host,tracker,true,"(","");ok(tracker.beforeCommit(prepared.intent,7,host.connection,"()",SymbolPairInputConnection.read(host.connection),false)==null,"same async intent cannot be reused");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");final boolean[] current={true};host.onRead=()->current[0]=false;ok(SymbolPairInputConnection.erase(tracker,host.connection,7,true,()->current[0])&&host.deleteCalls==0,"scope lost during read consumes action without stale fallback");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");final SymbolPairing.Tracker invalidated=tracker;host.onRead=invalidated::invalidate;ok(!erase(host,tracker)&&host.deleteCalls==0,"receipt invalidated reentrantly during snapshot");
  for(boolean mutate:new boolean[]{false,true}){host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");host.reject=true;host.mutateOnReject=mutate;ok(erase(host,tracker)&&host.deleteCalls==1&&!tracker.hasReceipt(),"rejected/uncertain native delete never double-retries");}
  host=new Host(String.join("",Collections.nCopies(200,"甲")),"尾");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");ok(erase(host,tracker)&&host.text.length()==201,"bounded context with long document");
  host=new Host("(",")");host.throwBatch=true;ok(!SymbolPairInputConnection.beginBatch(host.connection),"optional batch rejects safely");SymbolPairInputConnection.endBatch(host.connection);host.throwSelection=true;ok(!SymbolPairInputConnection.moveCaret(host.connection,1),"selection API exception falls back safely");
  host=new Host("","");tracker=new SymbolPairing.Tracker();insert(host,tracker,true,"(","");host.throwDelete=true;ok(erase(host,tracker)&&host.deleteCalls==1&&!tracker.hasReceipt(),"uncertain native exception cannot double-delete");
  System.out.println("PASS "+checks+" Android own-pair deletion host assertions (synthetic InputConnection; not physical IME)");
 }
}
