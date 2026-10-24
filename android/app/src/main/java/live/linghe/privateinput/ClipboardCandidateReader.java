package live.linghe.privateinput;
import android.app.KeyguardManager;
import android.content.*;
import android.os.PersistableBundle;
import android.provider.Settings;
import android.view.inputmethod.EditorInfo;

/** Native read capability only; no pairing, network or archive consent implied. */
final class ClipboardCandidateReader {
 static String metadata(Context context,EditorInfo editor,boolean visible){
  if(!visible||editor==null||!ActivityArchiveRules.safeInput(editor.inputType,editor.imeOptions,true))return "unavailable";
  KeyguardManager lock=(KeyguardManager)context.getSystemService(Context.KEYGUARD_SERVICE);if(lock!=null&&lock.isKeyguardLocked())return "unavailable";
  try{
   String selected=Settings.Secure.getString(context.getContentResolver(),Settings.Secure.DEFAULT_INPUT_METHOD);if(selected==null||!selected.startsWith(context.getPackageName()+"/"))return "unavailable";
   ClipboardManager clipboard=(ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE);if(clipboard==null)return "unavailable";
   ClipDescription d=clipboard.getPrimaryClipDescription();if(d==null)return "empty-or-denied";
   // No payload is fetched on unchanged metadata. Timestamp-less providers are
   // intentionally rechecked while visible; they cannot prove an unchanged copy.
   if(d.getTimestamp()<=0)return null;
   PersistableBundle e=d.getExtras();return d.getTimestamp()+":"+d.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)+":"+(e!=null&&e.getBoolean("android.content.extra.IS_SENSITIVE",false));
  }catch(RuntimeException denied){return "unavailable";}
 }
 static ClipboardCandidateState.Value read(Context context,EditorInfo editor,boolean inputVisible){
  if(!inputVisible||editor==null||!ActivityArchiveRules.safeInput(editor.inputType,editor.imeOptions,true))return null;
  KeyguardManager lock=(KeyguardManager)context.getSystemService(Context.KEYGUARD_SERVICE);if(lock!=null&&lock.isKeyguardLocked())return null;
  try{
   String selected=Settings.Secure.getString(context.getContentResolver(),Settings.Secure.DEFAULT_INPUT_METHOD);if(selected==null||!selected.startsWith(context.getPackageName()+"/"))return null;
   ClipboardManager clipboard=(ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE);if(clipboard==null)return null;
   ClipDescription description=clipboard.getPrimaryClipDescription();if(description==null||!description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN))return null;
   // Re-check the returned snapshot: another app may replace the board
   // between reading its metadata and obtaining the ClipData.
   return decode(clipboard.getPrimaryClip());
  }catch(RuntimeException denied){return null;}
 }
 static ClipboardCandidateState.Value decode(ClipData data){
  if(data==null||data.getItemCount()!=1)return null;ClipDescription description=data.getDescription();if(description==null||!description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN))return null;
  PersistableBundle extras=description.getExtras(); // Retain snapshot metadata; the marker does not reject readable text.
  ClipData.Item item=data.getItemAt(0);if(item.getUri()!=null||item.getIntent()!=null||item.getText()==null)return null;
  return ClipboardCandidateState.Value.create(item.getText().toString(),description.getTimestamp(),extras!=null&&extras.getBoolean("live.linghe.clipboard.auto.incoming",false));
 }
 private ClipboardCandidateReader(){}
}
