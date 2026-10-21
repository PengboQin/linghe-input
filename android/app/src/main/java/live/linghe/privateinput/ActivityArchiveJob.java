package live.linghe.privateinput;
import android.app.job.*;
/** OS-scheduled wake-up only; Android may defer it. No foreground-service promise. */
public final class ActivityArchiveJob extends JobService {
  @Override public boolean onStartJob(JobParameters parameters){ActivityArchiveManager.get(this).flush(error->jobFinished(parameters,error!=null));return true;}
  @Override public boolean onStopJob(JobParameters parameters){return true;}
}
