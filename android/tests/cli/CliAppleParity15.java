package live.linghe.privateinput;
import java.io.*;import java.util.*;
public final class CliAppleParity15 {
 private static void require(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 private static void type(long s,String text){NativeCore.clear(s);for(char c:text.toCharArray())NativeCore.key(s,c);}
 public static void main(String[]args){try{run(args);}catch(Throwable error){error.printStackTrace();System.exit(1);}}
 private static void run(String[]args)throws Exception{
  System.out.println("stage process="+new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get("/proc/self/stat"))).split(" ")[0]);
  long s=NativeCore.create(args[0],args[1]);require(s!=0,"engine");int checks=0;
  try{System.out.println("stage engine-ready");require(NativeCore.languageInitialize(args[0]),"public grammar");System.out.println("stage grammar-ready");CommonExpressionOrder order=new CommonExpressionOrder(new File(args[0],"essay.txt"),NativeCore::languageScore);
   require(order.frequency("都先")==237&&order.frequency("窦宪")==418&&order.frequency("时候")==144150&&order.frequency("不存在的合成词条甲")==0,"UTF8 mapped binary search");checks++;
   System.out.println("stage common-query");NativeCore.mode(s,false,true);type(s,"douxian");String[][] ordinary=NativeCore.snapshot(s),ranked=order.apply(ordinary,false,"",row->false);require(ranked[1][1].equals("都先"),"common expression first");require(Arrays.stream(ranked).anyMatch(row->row.length>=2&&row[1].equals("窦宪")),"rare word retained");require(NativeCore.draft(s)[0].equals("douxian"),"rank does not rewrite raw");NativeCore.choose(s,Long.parseLong(ranked[1][0]));require(NativeCore.snapshot(s)[0][1].equals("都先"),"native absolute commit");require(NativeCore.snapshot(s)[0][1].isEmpty(),"once");checks++;
   type(s,"douxian");ordinary=NativeCore.snapshot(s);ranked=order.apply(ordinary,false,"",row->row[1].equals("窦宪"));require(ranked[1][1].equals(ordinary[1][1]),"explicit pin or learning keeps rare slot");checks++;
   for(String raw:new String[]{"yixie","shihou","nihao","zhongguo"}){type(s,raw);ordinary=NativeCore.snapshot(s);ranked=order.apply(ordinary,false,"",row->false);require(ranked[1][1].equals(ordinary[1][1]),"strong native head "+raw);}checks++;
   NativeCore.mode(s,true,true);type(s,"3689426");for(String filter:new String[]{"dou","xian"}){String[] values=NativeCore.syllables(s);int index=Arrays.asList(values).indexOf(filter);require(index>=0,"filter "+filter);NativeCore.filter(s,index);}ordinary=NativeCore.snapshot(s);ranked=order.apply(ordinary,true,"",row->false);require(ranked[1][1].equals("都先"),"nine exact filtered reading common expression");checks++;
   List<String> words=java.nio.file.Files.readAllLines(new File(args[2],"mixed-english.txt").toPath());require(EnglishWordSuggestions.suggestions("aoole",words).contains("apple"),"near keys aoole");require(EnglishWordSuggestions.suggestions("appl",words).get(0).equals("apple"),"prefix apple");require(EnglishWordSuggestions.suggestions("AOOLE",words).contains("APPLE"),"case preservation");require(EnglishWordSuggestions.suggestions("a@o",words).isEmpty(),"not an English word");require(Math.abs(EnglishWordSuggestions.correctionCost("aoole","apple")-1.1)<1e-8,"same QWERTY edit cost as Apple");checks++;
   require(PinyinMatch.isFullSpelling("lue","lve")&&PinyinMatch.isFullSpelling("lve","lue")&&PinyinMatch.isFullSpelling("nue","nve"),"u/v pinyin syllable aliases");require(PinyinMatch.covers("lueguo","lve guo",0),"full alias is not an abbreviation");require(!PinyinMatch.isFullSpelling("blue","blve"),"no generic English rewrite");checks++;
   NativeCore.mode(s,false,true);type(s,"lue");ordinary=NativeCore.snapshot(s);require(Arrays.stream(ordinary).anyMatch(row->row.length>=2&&row[1].equals("略")),"updated real Rime alias resource");checks++;
   System.out.println("Passed "+checks+" Apple-parity15 groups; real mapped grammar, public frequency, both layouts, protected preference, absolute commit, English QWERTY correction and pinyin aliases");
  }finally{NativeCore.destroy(s);}
 }
}
