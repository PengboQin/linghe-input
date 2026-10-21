package live.linghe.privateinput;
import java.io.*;import java.util.*;

/** Actual pinned Rime, fresh public fixture, no installed-app data or UI. */
public final class CliQualityCheck {
 private static long session;private static int checks;
 private static void require(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 private static void type(String raw){for(char c:raw.toCharArray())NativeCore.key(session,c);}
 private static int find(String[][] rows,String text){for(int i=1;i<rows.length;i++)if(rows[i][1].equals(text))return i;return -1;}
 private static InputQuality.Repair repair(InputQuality quality,String raw,boolean nine,String text) {
  NativeCore.mode(session,nine,true);type(raw);String[][] original=NativeCore.snapshot(session);long started=System.nanoTime();
  List<InputQuality.Repair> values=quality.repairs(session,original,nine,"","",()->false);
  require(NativeCore.draft(session)[0].equals(raw),"query preserves "+raw);
  System.out.println("repair "+raw+" count="+values.size()+" ms="+((System.nanoTime()-started)/1000000));
  for(InputQuality.Repair value:values)if(value.text.equals(text))return value;
  if(raw.equals("4226"))for(String[] row:NativeCore.query(session,"426",true,32))System.out.println("synthetic426 "+Arrays.toString(row));
  throw new AssertionError(raw+" missing "+text+" found "+values.stream().map(v->v.text+"/"+v.spelling).reduce("",(a,b)->a+","+b));
 }
 private static void commit(InputQuality.Repair repair,String expectedRemainder) {
  System.out.println("commit begin "+repair.spelling);
  String[] result=NativeCore.commitAlternative(session,repair.raw,repair.spelling,repair.text,repair.remainder);require(result.length==2,"valid stage");session=Long.parseLong(result[0]);require(result[1].equals(repair.text),"stage exact output");String[][] state=NativeCore.snapshot(session);require(state[0][1].isEmpty(),"staged native commit drained");require(state[0][2].equals(expectedRemainder),"all remainder keys retained");require(NativeCore.snapshot(session)[0][1].isEmpty(),"no duplicate commit");checks++;
 }
 public static void main(String[] args){try{run(args);}catch(Throwable error){error.printStackTrace();System.exit(1);}}
 private static void run(String[] args)throws Exception {
  System.out.println("process "+new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get("/proc/self/stat")),java.nio.charset.StandardCharsets.UTF_8).split(" ")[0]);
  session=NativeCore.create(args[0],args[1]);require(session!=0,"Rime initialization");
  try {
   InputQuality quality=new InputQuality(new File(args[2]));
   commit(repair(quality,"shshenme",false,"是什么"),"");
   commit(repair(quality,"linaxaing",false,"联想"),"");
   commit(repair(quality,"nihaoo",false,"你好"),"");
   commit(repair(quality,"haoo",false,"好"),"");
   commit(repair(quality,"4226",true,"好"),"");
   for(String raw:new String[]{"644226","6446","64526"})commit(repair(quality,raw,true,"你好"),"");
   // Wrong or stale target leaves a selected Chinese prefix and draft intact.
   NativeCore.mode(session,true,true);type("64426");String[][] rows=NativeCore.snapshot(session);int index=find(rows,"你");require(index>0,"partial selection");NativeCore.choose(session,Long.parseLong(rows[index][0]));String[] draft=NativeCore.draft(session);require(draft[1].equals("你"),"prefix selected");
   require(NativeCore.commitAlternative(session,draft[0],"hao","错误😀","").length==0,"bad Unicode target rejected");require(Arrays.equals(draft,NativeCore.draft(session)),"failure preserves draft and prefix");
   require(NativeCore.commitAlternative(session,"stale","hao","好","").length==0,"stale stage rejected");checks++;
   String[] valid=NativeCore.commitAlternative(session,draft[0],"hao","好","");require(valid.length==2,"prefix stage valid");session=Long.parseLong(valid[0]);require(valid[1].equals("你好"),"Chinese prefix committed once");require(NativeCore.snapshot(session)[0][1].isEmpty(),"no duplicate prefix commit");checks++;
   // Recover one prefix and keep every malformed key after it.
   NativeCore.mode(session,false,true);type("nihaovvvvvv");String expected=NativeCore.draft(session)[0];String[] prefix=NativeCore.commitAlternative(session,expected,"nihao","你好","vvvvvv");require(prefix.length==2,"partial stage");session=Long.parseLong(prefix[0]);require(prefix[1].equals("你好")&&NativeCore.draft(session)[0].equals("vvvvvv"),"partial suffix retained");checks++;
   NativeCore.mode(session,true,true);type("968");rows=NativeCore.snapshot(session);require(rows[1][1].equals("有"),"you remains native first");List<InputQuality.Repair> suggestions=quality.repairs(session,rows,true,"","",()->true);require(suggestions.isEmpty(),"cancellation returns no proposals");require(NativeCore.draft(session)[0].equals("968"),"cancel preserves raw");checks++;
   NativeCore.mode(session,false,true);type("nihao");rows=NativeCore.snapshot(session);require(quality.repairs(session,rows,false,"","",()->false).isEmpty(),"normal spelling keeps native order");checks++;
   require(quality.suggestions("因为天气很好，").stream().anyMatch(v->v.text.equals("所以")),"punctuation continuation");checks++;
   NativeCore.mode(session,true,true);type("64426");String before=NativeCore.draft(session)[0];for(int i=0;i<100;i++){NativeCore.query(session,"nihao",false,8);NativeCore.query(session,"64426",true,8);}require(NativeCore.draft(session)[0].equals(before),"reused alternating probes isolated");checks++;
   NativeCore.mode(session,true,true);type("968");rows=NativeCore.snapshot(session);
   List<InputQuality.Repair> nineRepairs=quality.repairs(session,rows,true,"","",()->false);Map<String,InputQuality.Repair> plans=new HashMap<>();
   String[][] merged=quality.merged(rows,rows,nineRepairs,true,plans);require(merged[1][1].equals("有"),"normal you stays first after repair merge");checks++;
   String[][] custom=new String[rows.length+1][];custom[0]=rows[0];custom[1]=new String[]{"custom:fixture","合成个人词","you"};System.arraycopy(rows,1,custom,2,rows.length-1);
   merged=quality.merged(rows,custom,nineRepairs,true,plans);require(merged[1][0].equals("custom:fixture"),"explicit personal first");checks++;
   NativeCore.mode(session,false,true);type("shshenme");rows=NativeCore.snapshot(session);List<InputQuality.Repair> pinyinRepairs=quality.repairs(session,rows,false,"","",()->false);
   merged=quality.merged(rows,rows,pinyinRepairs,false,plans);require(Arrays.stream(merged).anyMatch(row->row.length>=2&&row[1].equals("是什么")),"omitted-vowel target remains selectable after merging");Set<String> unique=new HashSet<>();for(int i=1;i<merged.length;i++)require(unique.add(merged[i][1]),"no duplicate displayed words");checks++;
   NativeCore.mode(session,true,true);type("644226");rows=NativeCore.snapshot(session);index=find(rows,"你");require(index>0,"typo prefix selectable");NativeCore.choose(session,Long.parseLong(rows[index][0]));rows=NativeCore.snapshot(session);
   List<InputQuality.Repair> suffixRepairs=quality.repairs(session,rows,true,"","",()->false);System.out.println("prefix fixture raw="+rows[0][2]+" prefix="+rows[0][4]+" start="+NativeCore.editableStart(session)+" proposals="+suffixRepairs.stream().map(v->v.text+"/"+v.spelling).reduce("",(a,b)->a+","+b));InputQuality.Repair suffixRepair=suffixRepairs.stream().filter(value->value.text.equals("好")).findFirst().orElseThrow(()->new AssertionError("selected prefix tail recall"));
   String[] correctedPrefix=NativeCore.commitAlternative(session,suffixRepair.raw,suffixRepair.spelling,suffixRepair.text,suffixRepair.remainder);require(correctedPrefix.length==2,"corrected prefix commit");session=Long.parseLong(correctedPrefix[0]);require(correctedPrefix[1].equals("你好"),"selected prefix retained through actual repair");checks++;
   NativeCore.mode(session,false,false);type("nihaoo");rows=NativeCore.snapshot(session);InputQuality.Repair learned=quality.repairs(session,rows,false,"","",()->false).stream().filter(value->value.text.equals("你好")).findFirst().orElseThrow(()->new AssertionError("public learning correction"));commit(learned,"");
   ContextWindow window=ContextWindow.excludingMarked("前面"+String.join("",Collections.nCopies(30,"你"))+"nihao","后面","nihao");require(window.before.equals(String.join("",Collections.nCopies(20,"你")))&&window.after.equals("后面"),"bounded context excludes composition");
   require(ContextWindow.excludingMarked("unrelated","after","nihao")==ContextWindow.EMPTY,"unrecognized marked range fails closed");
   ContextWindow emoji=new ContextWindow(String.join("",Collections.nCopies(30,"😀")),String.join("",Collections.nCopies(30,"😀")));require(emoji.before.codePointCount(0,emoji.before.length())==20&&emoji.after.codePointCount(0,emoji.after.length())==20,"no surrogate split");checks++;
   System.out.println("Passed "+checks+" isolated actual-Rime correction, transaction, prefix and continuation checks");
  }finally{NativeCore.destroy(session);}
 }
}
