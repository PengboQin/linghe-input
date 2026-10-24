package live.linghe.privateinput;
import java.util.*;
/** Deliberate symbol taps only. Candidate output, paste and shared text stay raw. */
final class SymbolPairing {
 static final class Plan{final String insertedText;final int caretBack;final boolean generated;Plan(String text,int back){this(text,back,false);}Plan(String text,int back,boolean generated){insertedText=text;caretBack=back;this.generated=generated;}}
 private static final Map<String,String> PAIRS;
 static{Map<String,String> m=new LinkedHashMap<>();String[][] pairs={{"(",")"},{"（","）"},{"[","]"},{"【","】"},{"{","}"},{"《","》"},{"〈","〉"},{"「","」"},{"『","』"},{"“","”"},{"‘","’"},{"\"","\""}};for(String[] pair:pairs)m.put(pair[0],pair[1]);PAIRS=Collections.unmodifiableMap(m);}
 static Plan plan(String symbol,boolean autoPair,boolean caretInside){String closer=autoPair?PAIRS.get(symbol):null;return closer==null?new Plan(symbol,0):new Plan(symbol+closer,caretInside?closer.length():0,true);}

 /** In-memory provenance, never inferred from adjacent punctuation or persisted. */
 static final class Snapshot {
  static final int WINDOW=64;
  final int start,end;final String before,after;
  Snapshot(int start,int end,String before,String after){this.start=start;this.end=end;this.before=tail(before);this.after=head(after);}
  boolean collapsed(){return start>=0&&start==end;}
  static String tail(String text){return text.substring(Math.max(0,text.length()-WINDOW));}
  static String head(String text){return text.substring(0,Math.min(WINDOW,text.length()));}
  boolean same(Snapshot other){return other!=null&&start==other.start&&end==other.end&&before.equals(other.before)&&after.equals(other.after);}
 }
 static final class Intent {
  final long generation;final int document;final Object connection;final Plan plan;volatile boolean appended;private boolean claimed;
  Intent(long generation,int document,Object connection,Plan plan){this.generation=generation;this.document=document;this.connection=connection;this.plan=plan;}
 }
 static final class Insertion {
  final Intent intent;final Snapshot expected;final int beforeCaret,committedCaret;
  Insertion(Intent intent,Snapshot expected,int beforeCaret,int committedCaret){this.intent=intent;this.expected=expected;this.beforeCaret=beforeCaret;this.committedCaret=committedCaret;}
 }
 static final class Deletion {final int before,after;final long generation;Deletion(int before,int after,long generation){this.before=before;this.after=after;this.generation=generation;}}
 static final class Tracker {
  private long generation;private Insertion inserting,receipt;
  synchronized void invalidate(){generation++;inserting=null;receipt=null;}
  synchronized boolean hasReceipt(){return receipt!=null;}
  synchronized Intent intent(int document,Object connection,Plan plan){invalidate();return new Intent(generation,document,connection,plan);}
  synchronized Insertion beforeCommit(Intent intent,int document,Object connection,String output,Snapshot before,boolean composing){
   // A replacement of a composing span has no reliable range in ExtractedText.
   // Such a commit remains normal input, but cannot grant a deletion receipt.
   if(intent==null||!intent.appended||intent.claimed||intent.generation!=generation||intent.document!=document||intent.connection!=connection||connection==null||!intent.plan.generated||composing||before==null||!before.collapsed()||!output.endsWith(intent.plan.insertedText))return null;
   int committed=before.start+output.length(),back=intent.plan.caretBack;
   if(committed<before.start||back<0||back>output.length())return null;
   Snapshot expected=new Snapshot(committed-back,committed-back,before.before+output.substring(0,output.length()-back),output.substring(output.length()-back)+before.after);
   intent.claimed=true;inserting=new Insertion(intent,expected,before.start,committed);receipt=null;return inserting;
  }
  synchronized void committed(Insertion insertion,Snapshot actual){
   if(insertion==null||inserting!=insertion||insertion.intent.generation!=generation)return;
   inserting=null;receipt=insertion.expected.same(actual)?insertion:null;
  }
  synchronized void selectionChanged(int oldStart,int oldEnd,int start,int end){
   if(inserting!=null){if(start!=end||start!=inserting.beforeCaret&&start!=inserting.committedCaret&&start!=inserting.expected.start)invalidate();}
   else if(receipt!=null){if(start!=receipt.expected.start||end!=receipt.expected.end)invalidate();}
   else if(oldStart!=start||oldEnd!=end)invalidate();
  }
  synchronized Deletion take(int document,Object connection,Snapshot actual,boolean enabled){
   Insertion saved=receipt;receipt=null;inserting=null;
   if(saved==null||!enabled||saved.intent.generation!=generation||saved.intent.document!=document||saved.intent.connection!=connection||!saved.expected.same(actual))return null;
   Plan plan=saved.intent.plan;int after=plan.insertedText.substring(plan.insertedText.length()-plan.caretBack).codePointCount(0,plan.caretBack);
   int before=plan.insertedText.codePointCount(0,plan.insertedText.length())-after;
   return new Deletion(before,after,++generation);
  }
  synchronized boolean active(Deletion deletion){return deletion!=null&&deletion.generation==generation;}
 }
}
