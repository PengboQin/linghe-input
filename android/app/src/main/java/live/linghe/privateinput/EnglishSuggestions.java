package live.linghe.privateinput;
import java.util.*;

/** The same small first-party mixed-English vocabulary/rules as iOS. */
final class EnglishSuggestions {
 final List<String> words;
 EnglishSuggestions(List<String> words){this.words=new ArrayList<>(words);}
 static boolean valid(String word){return word.length()>=2&&word.length()<=32&&word.matches("[a-zA-Z]+");}
 static String code(String word){StringBuilder out=new StringBuilder();for(char c:word.toLowerCase(Locale.ROOT).toCharArray()){if(c<'a'||c>'z')return "";out.append(c<='c'?'2':c<='f'?'3':c<='i'?'4':c<='l'?'5':c<='o'?'6':c<='s'?'7':c<='v'?'8':'9');}return out.toString();}
 List<String> suggestions(String input,boolean nine){
  ArrayList<String> result=new ArrayList<>();Set<String> seen=new HashSet<>();if(input.isEmpty()||input.length()>32)return result;
  if(nine){if(input.length()<2||!input.matches("[2-9]+"))return result;for(String word:words){if(input.length()<5&&word.equals(word.toLowerCase(Locale.ROOT)))continue;if(code(word).equals(input)&&seen.add(word.toLowerCase(Locale.ROOT))){result.add(word);if(result.size()==4)break;}}return result;}
  String lower=input.toLowerCase(Locale.ROOT);if(lower.length()<2||!lower.matches("[a-z]+"))return result;
  for(int pass=0;pass<2;pass++)for(String word:words){String key=word.toLowerCase(Locale.ROOT);if(valid(word)&&key.startsWith(lower)&&(pass==0?key.equals(lower):lower.length()>=3&&!key.equals(lower))&&seen.add(key)){result.add(word);if(result.size()==4)return result;}}
  return result;
 }
}
