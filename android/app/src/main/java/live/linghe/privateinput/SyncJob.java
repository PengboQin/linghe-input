package live.linghe.privateinput;
import android.app.job.*;
import android.content.*;
public final class SyncJob extends JobService {
  static void schedule(Context c){
    android.content.SharedPreferences p=c.getSharedPreferences("sync-consent",0);
    JobScheduler jobs=c.getSystemService(JobScheduler.class);
    if(!p.getBoolean("learning",false)&&!p.getBoolean("clipboard",false)){
      jobs.cancel(17001);
      return;
    }
    jobs.schedule(new JobInfo.Builder(17001,new ComponentName(c,SyncJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(15*60*1000L).setPersisted(false).build());
  }
  @Override public boolean onStartJob(JobParameters params){
    SyncTasks.worker.execute(()->{
      boolean retry=false;try{
        new SyncClient(this).synchronize();
      }
      catch(Exception error){
        retry=true;
      }
      jobFinished(params,retry);
    }
    );
    return true;
  }
  @Override public boolean onStopJob(JobParameters params){
    return true;
  }
}
