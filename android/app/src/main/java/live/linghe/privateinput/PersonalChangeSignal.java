package live.linghe.privateinput;
import android.content.*;
/** Package-local invalidation; no entries or host text travel in the signal. */
final class PersonalChangeSignal {
 static final String ACTION="live.linghe.privateinput.PERSONAL_CHANGED";
 static void notifyChanged(Context context){context.sendBroadcast(new Intent(ACTION).setPackage(context.getPackageName()));}
}
