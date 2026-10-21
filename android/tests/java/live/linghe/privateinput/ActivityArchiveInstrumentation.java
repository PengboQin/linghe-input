package live.linghe.privateinput;
import android.app.Instrumentation;
import android.os.Bundle;
import java.io.File;
/** Normal test-App context; fresh synthetic directory only, no product data or clipboard. */
public final class ActivityArchiveInstrumentation extends Instrumentation {
  @Override public void onCreate(Bundle arguments){super.onCreate(arguments);start();}
  private static void remove(File file){File[] children=file.listFiles();if(children!=null)for(File child:children)remove(child);file.delete();}
  @Override public void onStart(){Bundle result=new Bundle();File directory=new File(getTargetContext().getFilesDir(),"archive-synthetic-"+ActivityArchiveRules.id());try{result.putString("result",ActivityArchiveQueueCheck.run(directory).toString());finish(-1,result);}catch(Throwable failure){result.putString("error",failure.getClass().getSimpleName()+": "+failure.getMessage());finish(1,result);}finally{remove(directory);}}
}
