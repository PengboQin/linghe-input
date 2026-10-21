package live.linghe.privateinput;
import java.nio.file.*;import java.util.*;
public final class InputAlgorithmsTest {
 static void require(boolean b,String name){if(!b)throw new AssertionError(name);}
 public static void main(String[] args)throws Exception{
  EnglishSuggestions words=new EnglishSuggestions(Files.readAllLines(Paths.get(args[0])));
  require(words.suggestions("api",false).equals(Arrays.asList("API")),"exact known English case");
  require(words.suggestions("git",false).equals(Arrays.asList("GitHub","GitLab")),"prefix completions");
  require(words.suggestions("hel",false).equals(Arrays.asList("hello","help")),"stable common completion order");
  require(words.suggestions("he",false).isEmpty(),"two-letter completion not intrusive");
  require(words.suggestions("274",true).equals(Arrays.asList("API")),"nine-key acronym");
  require(words.suggestions("43556",true).equals(Arrays.asList("hello")),"nine-key exact long word");
  require(words.suggestions("968",true).isEmpty(),"short normal Chinese codes not flooded by English");
  require(words.suggestions("ni'426",true).isEmpty(),"explicit syllables protected");
  require(words.suggestions("a'p'i",false).isEmpty(),"Latin guards");
  Map<String,Long> counts=new HashMap<>();counts.put("⊂",5L);counts.put("。",2L);
  List<String> result=SymbolOrder.ordered(Arrays.asList("，","。"),Arrays.asList("，","。","⊂","Ω"),counts,64);
  require(result.equals(Arrays.asList("⊂","。","，")),"used special symbol joins common list by frequency");
  require(SymbolOrder.ordered(Arrays.asList("，","。"),Arrays.asList("Ω"),new HashMap<>(),64).equals(Arrays.asList("，","。")),"stable default seed order");
  require(SymbolOrder.ordered(Arrays.asList("，","。"),Arrays.asList("Ω"),counts,1).size()==1,"bounded result");
  System.out.println("PASS 12 host rules: mixed-English recall/protected spellings and adaptive common symbols");
 }
}
