package live.linghe.privateinput;
public final class InputQualityDraftTest {
 private static int checks;
 private static void check(boolean value,String why){if(!value)throw new AssertionError(why);checks++;}
 public static void main(String[] args){
  check(InputQuality.keyAlignedDraft("77777","ran qi re shui qi").equals("r q r s q"),"first candidate initials");
  check(InputQuality.keyAlignedDraft("44444","ha ha ha ha ha").equals("h h h h h"),"repeated ha initials");
  check(InputQuality.keyAlignedDraft("647486742","ni shuo sha").equals("ni shuo sha"),"full reading aligned to nine keys");
  check(InputQuality.keyAlignedDraft("3332","de dao").equals("e e e b"),"canonical fallback");
  check(InputQuality.keyAlignedDraft("8885","tu").equals("u u u k"),"ellipsis/expansion fallback");
  check(InputQuality.keyAlignedDraft("44","he he").equals("h h"),"no untyped e in display");
  check(!AutoPhrase.storableText("好🙂"),"emoji phrase rejected");
  check(!AutoPhrase.storableText("👨‍👩‍👧‍👦"),"ZWJ phrase rejected");
  check(AutoPhrase.storableText("你好"),"Chinese phrase accepted");
  System.out.println("PASS InputQualityDraftTest assertions="+checks);
 }
}
