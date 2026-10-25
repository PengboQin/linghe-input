package live.linghe.privateinput;

import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;

/** Automatic phrase collection: pairs a committed phrase with its full reading and remembers announcements. */
final class AutoPhrase {
 private AutoPhrase(){}
 static final String ANNOUNCED="auto-phrase-announced";
 static final int ANNOUNCED_LIMIT=500;

 /** Accumulates the selections of one composition on the native worker thread only. */
 static final class Tracker {
  private final ArrayList<String> texts=new ArrayList<>(),readings=new ArrayList<>();
  private boolean broken;
  private String joinedText(){StringBuilder out=new StringBuilder();for(String part:texts)out.append(part);return out.toString();}
  /** Records one candidate choice; prefix is the text already selected before it. */
  void selected(String prefix,String text,String reading){
   if(prefix==null||prefix.isEmpty()){reset();}
   else if(broken||!prefix.equals(joinedText())){broken=true;return;}
   if(text==null||text.isEmpty()||reading==null||reading.trim().isEmpty()){broken=true;return;}
   texts.add(text);readings.add(reading.trim());
  }
  /** Returns the full reading when commit is exactly the tracked selections, then resets. */
  String committed(String commit){
   if(commit==null||commit.isEmpty())return null;
   String result=!broken&&!texts.isEmpty()&&commit.equals(joinedText())?String.join(" ",readings):null;
   reset();return result;
  }
  void reset(){texts.clear();readings.clear();broken=false;}
 }

 static String key(String text,String reading){return text+"\u001f"+reading;}

 /** True once per text/reading so the same phrase is never announced twice. */
 static synchronized boolean firstAnnouncement(SharedPreferences preferences,String text,String reading){
  Set<String> stored=preferences.getStringSet(ANNOUNCED,null);
  Set<String> next=stored==null?new HashSet<>():new HashSet<>(stored);
  if(!next.add(key(text,reading)))return false;
  if(next.size()>ANNOUNCED_LIMIT)next.remove(next.iterator().next());
  preferences.edit().putStringSet(ANNOUNCED,next).apply();
  return true;
 }

 /** Visible notice for one committed phrase in one editor. */
 static final class Notice {
  final int document;final String text,reading;final long shownAt;
  Notice(int document,String text,String reading,long shownAt){this.document=document;this.text=text;this.reading=reading;this.shownAt=shownAt;}
 }
}
