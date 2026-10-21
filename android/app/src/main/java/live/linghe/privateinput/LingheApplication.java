package live.linghe.privateinput;
import android.app.*;import android.os.*;
/** Foreground app coordinator, independent of which settings page is visible.
 * No activity means no foreground polling; input callbacks never run network. */
public final class LingheApplication extends Application implements Application.ActivityLifecycleCallbacks {
 private final Handler main=new Handler(Looper.getMainLooper());private int resumed;private boolean running;
 static volatile String syncError="";
 private final Runnable poll=()->{
  if(resumed==0||running)return;running=true;
  SyncTasks.worker.execute(()->{
   long delay=15000;String error="";
   try{SyncClient client=new SyncClient(this);AutoClipboardBridge automatic=AutoClipboardBridge.get(this);automatic.synchronizeActive(client);if(automatic.enabled())delay=automatic.activePollDelay(true);org.json.JSONObject ticket=client.ticket();if(client.joining()&&!client.joiningExpired()||ticket!=null&&ticket.optLong("expiresAt",0)>System.currentTimeMillis()/1000)delay=3000;}
   catch(Exception failure){error="暂时无法连接同步服务，将自动重试";AutoClipboardBridge automatic=AutoClipboardBridge.get(this);if(automatic.enabled())delay=automatic.activePollDelay(false);}
   long next=delay;String status=error;main.post(()->{running=false;syncError=status;main.removeCallbacks(LingheApplication.this.poll);if(resumed>0)main.postDelayed(LingheApplication.this.poll,next);});
  });
 };
 @Override public void onCreate(){super.onCreate();registerActivityLifecycleCallbacks(this);ActivityArchiveManager.get(this);AutoClipboardBridge.get(this);}
 public void onActivityResumed(Activity activity){ActivityArchiveManager.get(this).foreground(true);AutoClipboardBridge.get(this).foreground(true);resumed++;main.removeCallbacks(LingheApplication.this.poll);if(!running)main.post(LingheApplication.this.poll);}
 public void onActivityPaused(Activity activity){ActivityArchiveManager.get(this).foreground(false);AutoClipboardBridge.get(this).foreground(false);resumed=Math.max(0,resumed-1);if(resumed==0)main.removeCallbacks(LingheApplication.this.poll);}
 public void onActivityCreated(Activity a,Bundle b){}public void onActivityStarted(Activity a){}public void onActivityStopped(Activity a){}public void onActivitySaveInstanceState(Activity a,Bundle b){}public void onActivityDestroyed(Activity a){}
}
