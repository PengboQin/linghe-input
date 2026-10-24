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
  require(!NativeCore.candidateReadingAllowed("小厂","xiao han"),"actual JNI rejects polluted aligned reading");
  require(NativeCore.candidateReadingAllowed("小厂","xiao chang"),"actual JNI accepts modern chang reading");
  require(NativeCore.candidateReadingAllowed("小寒","xiao han"),"actual JNI retains correct han carrier");
  require(NativeCore.candidateReadingAllowed("小厂",""),"missing reading remains unknown");
  require(NativeCore.candidateReadingAllowed("小厂",null),"null reading remains unknown through JNI");
  require(NativeCore.candidateReadingAllowed("小厂","xiao"),"unaligned reading remains unknown");
  require(NativeCore.candidateReadingAllowed("小厂","系统注释"),"opaque reading remains unknown");
  String[][] rows={{"0","小厂","xiao han"},{"learned:9","小厂","xiao han"},{"repair:2","小厂","xiao han"},
   {"path:3","小厂","xiao han"},{"assembly:4","小厂","xiao han"},{"pinned:5","小厂","xiao han"},
   {"6","小厂","xiao chang"},{"7","小寒","xiao han"},{"custom:alias","小厂","xiao han"},
   {"english:apple","apple","英文"},{"continuation:factory","小厂","xiao han"},{"custom:shortcut","小厂","别名"},
   {"8","小厂",""},{"9","小厂","xiao"}};
  String[][] original=Arrays.stream(rows).map(String[]::clone).toArray(String[][]::new);
  ArrayList<String> accepted=new ArrayList<>();
  for(int i=0;i<rows.length;i++){
   String[] row=rows[i];boolean allowed=GlyphAvailability.candidateDisplayable(row[1],NativeCore::candidateTextAllowed,point->true)
    &&AutomaticReadingAdmission.allows(row[0],row[1],row[2],NativeCore::candidateReadingAllowed);
   require(allowed==(i>=6),"production reading gate row "+row[0]);if(allowed)accepted.add(row[0]);
  }
  require(accepted.equals(Arrays.asList("6","7","custom:alias","english:apple","continuation:factory","custom:shortcut","8","9")),"filter retains source IDs/order without renumbering");
  require(Arrays.deepEquals(rows,original),"filter does not rewrite source rows or stored readings");
  require(!AutomaticReadingAdmission.allows("customized:fake","小厂","xiao han",NativeCore::candidateReadingAllowed),"only explicit custom prefix bypasses reading gate");
  require(!GlyphAvailability.candidateDisplayable("貓貓",NativeCore::candidateTextAllowed,point->true),"explicit alias does not bypass existing text policy");
  require(!GlyphAvailability.candidateDisplayable("小厂",NativeCore::candidateTextAllowed,point->false),"explicit alias still respects glyph veto");
  System.out.println("PASS "+checks+" actual JNI/core/admission checks; nativeSessions=false devices=false");
 }
}
