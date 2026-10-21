package live.linghe.privateinput;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Public resources and synthetic input only; no Context, UI or app data. */
public final class CliLanguageCheck {
 private static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
 private static String decode(String value){return new String(Base64.getDecoder().decode(value),StandardCharsets.UTF_8);}
 private static String[] pieces(String text){return text.isEmpty()?new String[0]:text.split(",");}
 private static void same(double actual,String expected,String message){require(Math.abs(actual-Double.parseDouble(expected))<1e-9,message+" "+actual+" != "+expected);}
 private static void nullable(Double actual,String expected,String message){if(expected.equals("nil"))require(actual==null,message);else{require(actual!=null,message);same(actual,expected,message);}}
 public static void main(String[] args)throws Exception {
  File resources=new File(args[0]);
  PublicLanguageData.Nine nine=new PublicLanguageData.Nine(new File(resources,"nine-lexicon.bin"));
  PublicLanguageData.Continuations continuation=new PublicLanguageData.Continuations(new File(resources,"continuation.bin"));
  Set<String> syllables=new HashSet<>(Files.readAllLines(new File(resources,"pinyin-syllables.txt").toPath(),StandardCharsets.UTF_8));syllables.remove("");
  PinyinCorrector corrector=new PinyinCorrector(syllables,text->{String code=NineSpelling.encode(text);return code==null?0:nine.frequency(code);});
  int count=0;long started=System.nanoTime();
  for(String line:Files.readAllLines(Paths.get(args[1]),StandardCharsets.UTF_8)) {
   String[] row=line.split("\t",-1);String raw=decode(row[1]);String label="vector "+(count+1)+" "+row[0]+" "+raw;
   switch(row[0]) {
    case "P": {
     List<PinyinCorrector.Proposal> values=corrector.proposals(raw,Integer.parseInt(row[2]));String[] expected=pieces(row[3]);require(values.size()==expected.length,label+" count "+values.size()+" != "+expected.length);
     for(int i=0;i<expected.length;i++){String[] v=expected[i].split(":");PinyinCorrector.Proposal p=values.get(i);require(p.spelling.equals(v[0])&&p.edits==Integer.parseInt(v[1]),label+" proposal "+i+" "+p.spelling+" != "+v[0]);same(p.cost,v[2],label+" cost");}break;
    }
    case "M":require(PinyinMatch.covers(raw,decode(row[2]),Integer.parseInt(row[3]))==Boolean.parseBoolean(row[4]),label);break;
    case "F":require(nine.frequency(raw)==Long.parseLong(row[2]),label);break;
    case "C": {
     List<PublicLanguageData.Suggestion> values=continuation.suggestions(raw,Integer.parseInt(row[2]));String[] expected=pieces(row[3]);require(values.size()==expected.length,label+" count "+values.size()+" != "+expected.length);
     for(int i=0;i<expected.length;i++){String[] v=expected[i].split(":");require(values.get(i).text.equals(decode(v[0])),label+" text "+i);same(values.get(i).score,v[1],label+" score");}break;
    }
    case "N": {
     List<NineSpelling.Alternative> values=NineSpelling.alternatives(raw,Integer.parseInt(row[2]));String[] expected=pieces(row[3]);require(values.size()==expected.length,label+" count");
     for(int i=0;i<expected.length;i++){String[] v=expected[i].split(":");require(values.get(i).input.equals(v[0]),label+" alternative "+i);same(values.get(i).cost,v[1],label+" cost");}break;
    }
    case "E":nullable(NineSpelling.editCost(raw,decode(row[2])),row[3],label+" edit");nullable(NineSpelling.jointEditCost(raw,decode(row[2])),row[4],label+" joint");break;
    default:throw new AssertionError("unknown vector type");
   }
   count++;
  }
  require(corrector.proposals("shshenme",64).stream().anyMatch(p->p.spelling.equals("shishenme")),"missing i recall");
  require(corrector.proposals("linaxaing",64).stream().anyMatch(p->p.spelling.equals("lianxiang")),"double swap recall");
  require(corrector.proposals("shshenme",64,()->true).isEmpty(),"cancelled work");
  // Malformed indexes must not be mapped as valid resources.
  File bad=new File(args[2]);Files.write(bad.toPath(),new byte[16]);boolean rejected=false;try{new PublicLanguageData.Nine(bad);}catch(IOException expected){rejected=true;}require(rejected,"bad header rejected");Files.delete(bad.toPath());
  System.out.println("Passed "+count+" Swift/Java public language vectors, repair recall, cancellation and malformed header; elapsedMs="+((System.nanoTime()-started)/1000000));
 }
}
