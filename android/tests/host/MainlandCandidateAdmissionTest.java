package live.linghe.privateinput;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
/** Host JVM calls the actual JNI adapter and shared native policy; no IME/session or device. */
public final class MainlandCandidateAdmissionTest {
 private static int checks;
 private static void require(boolean value,String why){if(!value)throw new AssertionError(why);checks++;}
 public static void main(String[] args){
  for(String value:Arrays.asList("有","猫猫","淘宝","天猫","吕明","深圳","GPT-5.2","apple","你好\n世界","☀️")){
   require(NativeCore.candidateTextAllowed(value),"native allows "+value);
   require(GlyphAvailability.candidateDisplayable(value,NativeCore::candidateTextAllowed,point->true),"final candidate allows "+value);
  }
  for(String value:Arrays.asList("貓貓","臺灣","𨈖","",null,"\uD888\uDFB0","\uD8BF\uDFFD","一\uDB40\uDD01")){
   AtomicInteger glyphChecks=new AtomicInteger();
   require(!NativeCore.candidateTextAllowed(value),"native rejects "+value);
   require(!GlyphAvailability.candidateDisplayable(value,NativeCore::candidateTextAllowed,point->{glyphChecks.incrementAndGet();return true;}),"renderer cannot bypass native policy "+value);
   require(glyphChecks.get()==0,"rejects before glyph work "+value);
  }
  require(!GlyphAvailability.candidateDisplayable("猫猫",NativeCore::candidateTextAllowed,point->false),"device glyph support remains an independent veto");
  require(!GlyphAvailability.candidateDisplayable("\ud840",NativeCore::candidateTextAllowed,point->true),"malformed Java surrogate is never accepted by JNI conversion");
  System.out.println("PASS "+checks+" actual JNI/core/admission checks; nativeSessions=false devices=false");
 }
}
