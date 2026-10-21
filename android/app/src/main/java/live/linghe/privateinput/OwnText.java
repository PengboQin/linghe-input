package live.linghe.privateinput;
import java.text.*;import java.util.*;

/** Grapheme-bounded own text; host plaintext never enters persistent context. */
final class OwnText {
 static List<String> characters(String text){ArrayList<String> out=new ArrayList<>();BreakIterator i=BreakIterator.getCharacterInstance(Locale.ROOT);i.setText(text);int a=i.first(),b;while((b=i.next())!=BreakIterator.DONE){out.add(text.substring(a,b));a=b;}return out;}
 static String suffix(String text,int count){List<String> c=characters(text);return String.join("",c.subList(Math.max(0,c.size()-count),c.size()));}
 static String dropLast(String text){List<String> c=characters(text);return String.join("",c.subList(0,Math.max(0,c.size()-1)));}
 static String append(String text,String previous){return suffix(previous+text,128);}
 static String preference(String text){StringBuilder out=new StringBuilder();List<String> chars=characters(Normalizer.normalize(text,Normalizer.Form.NFC));for(int i=chars.size()-1;i>=0;i--){String c=chars.get(i);if("。！？!?\n".contains(c))break;if(c.codePoints().anyMatch(Character::isLetterOrDigit))out.insert(0,c);}return suffix(out.toString(),12);}
 static boolean equal(String a,String b){return Normalizer.normalize(a,Normalizer.Form.NFC).equals(Normalizer.normalize(b,Normalizer.Form.NFC));}
}
