package live.linghe.privateinput;
import java.util.function.IntPredicate;
/** Check scalars separately: Paint.hasGlyph on a whole phrase can ask for one ligature. */
final class GlyphAvailability {
 static boolean displayable(String text,IntPredicate hasGlyph){if(text.isEmpty())return false;for(int i=0;i<text.length();){char c=text.charAt(i);if(Character.isSurrogate(c)&&(!Character.isHighSurrogate(c)||i+1>=text.length()||!Character.isLowSurrogate(text.charAt(i+1))))return false;int point=text.codePointAt(i);i+=Character.charCount(point);if(Character.isWhitespace(point)||point==0x200d||point>=0xfe00&&point<=0xfe0f||point>=0xe0100&&point<=0xe01ef)continue;if(!hasGlyph.test(point))return false;}return true;}
}
