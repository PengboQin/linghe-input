package live.linghe.privateinput;
import java.util.*;
import java.lang.reflect.Field;
/** Capacity characterization using production classes; no Android JSON/DB/device. */
public final class RimeCapacityBoundaryTest {
 static String dump(int size,int count){StringBuilder text=new StringBuilder();for(int i=0;i<size;i++)text.append("合成").append(i).append("\the cheng\t").append(i==0?count:1).append('\n');return text.toString();}
 static Object baseline(RimeCheckpoint s)throws Exception{Field f=RimeCheckpoint.class.getDeclaredField("observed");f.setAccessible(true);return new LinkedHashMap<>((Map<?,?>)f.get(s));}
 public static void main(String[]args)throws Exception{
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(dump(5000,1),"synthetic");state.setPinned("he cheng","合成0",true,"synthetic");state.model.remove("he cheng\u001f合成1");state.resetFrequency("he cheng","合成2");
  RimeCheckpoint before=state.copy();boolean rejected=false;try{state.observeExport(dump(5001,2),"synthetic");}catch(Exception expected){rejected=true;}
  boolean unchanged=state.model.entries().equals(before.model.entries())&&baseline(state).equals(baseline(before));
  if(!rejected||!unchanged||state.model.get("he cheng\u001f合成5000")!=null)throw new AssertionError("overflow must preserve original model and baseline");
  if(state.model.get("he cheng\u001f合成0").counts.get("synthetic")!=1)throw new AssertionError("known delta was unexpectedly consumed");
  state.observeExport(dump(5000,2),"synthetic");if(state.model.get("he cheng\u001f合成0").counts.get("synthetic")!=2)throw new AssertionError("known-only dump should still advance");
  if(!state.model.get("he cheng\u001f合成0").pinned||!state.model.get("he cheng\u001f合成1").deleted||state.model.get("he cheng\u001f合成2").generation.intValue()!=1)throw new AssertionError("controls changed");
  System.out.println("{\"positiveRowsAtBoundary\":5000,\"overflowPositiveRows\":5001,\"overflowRejectedBeforeObservation\":true,\"allOldEntriesAndControlsRetained\":true,\"existingDeltaBlockedWhenNewWordSharesOverflowDump\":true,\"existingOnlyDumpCanStillAdvanceCounter\":true,\"actualProductionCheckpointExecuted\":true,\"androidJsonNativeOrCoordinatorExecuted\":false,\"allDataSynthetic\":true}");
 }
}
