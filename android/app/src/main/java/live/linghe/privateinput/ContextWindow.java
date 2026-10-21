package live.linghe.privateinput;
import java.text.BreakIterator;import java.util.*;

/** Ephemeral, at most twenty character clusters on either side of composition. */
final class ContextWindow {
 static final ContextWindow EMPTY=new ContextWindow("","");
 final String before,after;
 ContextWindow(String before,String after){this.before=bounded(before,true);this.after=bounded(after,false);}
 private static String bounded(String text,boolean suffix) {
  if(text==null||text.isEmpty())return "";
  BreakIterator iterator=BreakIterator.getCharacterInstance(Locale.ROOT);iterator.setText(text);
  int boundary=suffix?iterator.last():iterator.first();
  for(int count=0;count<20;count++){int next=suffix?iterator.previous():iterator.next();if(next==BreakIterator.DONE)return text;boundary=next;}
  return suffix?text.substring(boundary):text.substring(0,boundary);
 }
 static ContextWindow excludingMarked(String before,String after,String marked) {
  if(marked!=null&&!marked.isEmpty()) {
   if(before==null||!before.endsWith(marked))return EMPTY;
   before=before.substring(0,before.length()-marked.length());
  }
  return new ContextWindow(before,after);
 }
}
