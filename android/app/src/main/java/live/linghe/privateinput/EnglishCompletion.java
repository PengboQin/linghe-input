package live.linghe.privateinput;

import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import java.util.*;

/** Only the current ASCII word is inspected; no history, learning or persistence. */
final class EnglishCompletion {
 static boolean allowed(EditorInfo info) {
  if(info==null||(info.inputType&InputType.TYPE_MASK_CLASS)!=InputType.TYPE_CLASS_TEXT)return false;
  if((info.inputType&InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)!=0)return false;
  int variation=info.inputType&InputType.TYPE_MASK_VARIATION;
  return variation!=InputType.TYPE_TEXT_VARIATION_PASSWORD&&variation!=InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD&&variation!=InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD&&variation!=InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS&&variation!=InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS&&variation!=InputType.TYPE_TEXT_VARIATION_URI;
 }
 static String prefix(InputConnection connection) {
  if(connection==null)return "";
  try {
   CharSequence selected=connection.getSelectedText(0);
   if(selected!=null&&selected.length()>0)return "";
   CharSequence after=connection.getTextAfterCursor(1,0);
   if(after!=null&&after.length()>0&&letter(after.charAt(0)))return "";
   CharSequence before=connection.getTextBeforeCursor(33,0);
   if(before==null)return "";
   int start=before.length();while(start>0&&letter(before.charAt(start-1)))start--;
   String word=before.subSequence(start,before.length()).toString();
   return word.length()>=2&&word.length()<=32?word:"";
  }catch(RuntimeException unavailable){return "";}
 }
 private static boolean letter(char c){return c>='a'&&c<='z'||c>='A'&&c<='Z';}
 static List<String> choices(EnglishSuggestions lexicon,String prefix) {
  if(prefix.isEmpty())return Collections.emptyList();
  return EnglishWordSuggestions.suggestions(prefix,lexicon.words);
 }

 /** Mark then replace in one commit; never delete text as a separate operation. */
 static boolean select(InputConnection connection,String expected,String word,int start,int end) {
  if(connection==null||expected.length()<2||expected.length()>32||start!=end||end<expected.length()||!EnglishSuggestions.valid(word)||(!word.toLowerCase(Locale.ROOT).startsWith(expected.toLowerCase(Locale.ROOT))&&EnglishWordSuggestions.correctionCost(expected.toLowerCase(Locale.ROOT),word.toLowerCase(Locale.ROOT))==null))return false;
  boolean batch=false,region=false;
  try {
   connection.beginBatchEdit();batch=true;
   if(!prefix(connection).equals(expected))return false;
   if(!connection.setComposingRegion(end-expected.length(),end))return false;
   region=true;
   return connection.commitText(word,1);
  }catch(RuntimeException unavailable){return false;}
  finally{if(region)try{connection.finishComposingText();}catch(RuntimeException ignored){}if(batch)try{connection.endBatchEdit();}catch(RuntimeException ignored){}}
 }
}
