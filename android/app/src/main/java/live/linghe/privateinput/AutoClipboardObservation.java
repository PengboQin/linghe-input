package live.linghe.privateinput;
/** The bridge supplies affirmative platform evidence; a denied/null read is not
 * permission to treat the clipboard as empty or overwrite a user's clear. */
final class AutoClipboardObservation {
 static boolean noDescription(AutoClipboardState state,String version,boolean changed,boolean activeUnlocked,boolean defaultIme,boolean hasPrimaryClip){
  if(!activeUnlocked)return false;
  boolean reliableEmpty=defaultIme&&!hasPrimaryClip;
  if(changed)state.observe(version,null,false);
  else if(reliableEmpty)state.establishEmptyBaseline(version);
  return reliableEmpty;
 }
}
