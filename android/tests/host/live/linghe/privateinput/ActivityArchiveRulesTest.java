package live.linghe.privateinput;
public final class ActivityArchiveRulesTest {
  static int assertions;
  static void check(boolean ok,String name){assertions++;if(!ok)throw new AssertionError(name);}
  public static void main(String[] args){
    check(!ActivityArchiveRules.safeInput(1,0,false),"unknown editor excluded");
    check(!ActivityArchiveRules.safeInput(0,0,true),"TYPE_NULL excluded");
    check(!ActivityArchiveRules.safeInput(15,0,true),"unknown kind excluded");
    check(!ActivityArchiveRules.safeInput(1,0x01000000,true),"no personalized excluded");
    check(!ActivityArchiveRules.safeInput(0x81,0,true),"password excluded");
    check(!ActivityArchiveRules.safeInput(0x91,0,true),"visible password excluded");
    check(!ActivityArchiveRules.safeInput(0xe1,0,true),"web password excluded");
    check(!ActivityArchiveRules.safeInput(0x12,0,true),"numeric password excluded");
    check(!ActivityArchiveRules.safeInput(0xf1,0,true),"unknown text variation excluded");
    check(!ActivityArchiveRules.safeInput(0x22,0,true),"unknown number variation excluded");
    check(!ActivityArchiveRules.safeInput(0x13,0,true),"unknown phone variation excluded");
    String a="00000000-0000-4000-8000-000000000001",b="00000000-0000-4000-8000-000000000002";
    check(ActivityArchiveRules.batchID(java.util.Arrays.asList(a,b)).equals(ActivityArchiveRules.batchID(java.util.Arrays.asList(a,b))),"batch stable on retry");
    check(!ActivityArchiveRules.batchID(java.util.Arrays.asList(a,b)).equals(ActivityArchiveRules.batchID(java.util.Arrays.asList(a))),"new event set new batch");
    check(!ActivityArchiveRules.batchID(java.util.Arrays.asList(a,b)).equals(ActivityArchiveRules.batchID(java.util.Arrays.asList(b,a))),"batch includes ordered seq");
    check(ActivityArchiveRules.safeInput(1,0,true),"text allowed");
    check(ActivityArchiveRules.safeInput(0x20001,0,true),"multiline allowed");
    check(ActivityArchiveRules.safeInput(2,0,true),"number allowed");
    check(ActivityArchiveRules.safeInput(3,0,true),"phone allowed");
    check(ActivityArchiveRules.safeInput(4,0,true),"datetime allowed");
    check(ActivityArchiveRules.utf8Length("合成abc😀\n")==14,"UTF8 scalar length");
    check(!ActivityArchiveRules.acceptedText(""),"empty not a commit");
    check(!ActivityArchiveRules.acceptedText("\ud800"),"invalid high surrogate not replaced");
    check(!ActivityArchiveRules.acceptedText("\udc00"),"invalid low surrogate not replaced");
    StringBuilder huge=new StringBuilder();for(int i=0;i<ActivityArchiveRules.MAX_TEXT_BYTES;i++)huge.append('a');
    check(ActivityArchiveRules.acceptedText(huge.toString()),"boundary preserved");huge.append('a');
    check(!ActivityArchiveRules.acceptedText(huge.toString()),"oversize rejected without truncation");
    check(ActivityArchiveRules.acceptedText("同样的文字"),"same content remains independently eligible");
    System.out.println("ActivityArchiveRulesTest: "+assertions+" assertions passed");
  }
}
