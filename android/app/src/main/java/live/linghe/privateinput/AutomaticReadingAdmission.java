package live.linghe.privateinput;
import java.util.function.BiPredicate;

/** Reading-only gate after the existing text/glyph check; never mutates rows or learning. */
final class AutomaticReadingAdmission {
 static boolean allows(String id,String text,String reading,BiPredicate<String,String> allowed){
  // These IDs identify explicit personal aliases, English or plain continuation
  // text. Automatic native/learned/repair/path/assembly rows have no exemption.
  if(id!=null&&(id.startsWith("custom:")||id.startsWith("english:")||id.startsWith("continuation:")))return true;
  return allowed.test(text,reading);
 }
}
