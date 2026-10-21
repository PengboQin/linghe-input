package live.linghe.privateinput;

/** Pure policy helpers. Unknown field security is excluded, never inferred from text. */
final class ActivityArchiveRules {
  static final int MAX_TEXT_BYTES=240*1024;
  static boolean safeInput(int inputType,int imeOptions,boolean editorKnown) {
    if(!editorKnown||(imeOptions&0x01000000)!=0)return false; // NO_PERSONALIZED_LEARNING
    int kind=inputType&15,variation=inputType&0xff0;
    if(kind==1)return variation<=0xd0&&variation!=0x80&&variation!=0x90;
    if(kind==2)return variation==0;
    return kind==3&&variation==0||kind==4&&variation<=0x20; // phone/datetime; TYPE_NULL and unknown are excluded.
  }
  static int utf8Length(String text) {
    if(text==null)return -1;long total=0;
    for(int i=0;i<text.length();i++) {
      char c=text.charAt(i);
      if(Character.isHighSurrogate(c)){if(i+1>=text.length()||!Character.isLowSurrogate(text.charAt(++i)))return -1;total+=4;}
      else if(Character.isLowSurrogate(c))return -1;
      else total+=c<0x80?1:c<0x800?2:3;
      if(total>MAX_TEXT_BYTES)return -1;
    }
    return(int)total;
  }
  static boolean acceptedText(String text){return text!=null&&!text.isEmpty()&&utf8Length(text)>=0;}
  static String id(){return java.util.UUID.randomUUID().toString().toUpperCase(java.util.Locale.ROOT);}
  static String id(String value){return java.util.UUID.fromString(value).toString().toUpperCase(java.util.Locale.ROOT);}
  static byte[] bytes(String value){return value.getBytes(java.nio.charset.StandardCharsets.UTF_8);}
  static String batchID(java.util.List<String> eventIDs){
    StringBuilder key=new StringBuilder("PrivateInput/android-archive-batch/v1\0");for(String event:eventIDs)key.append(id(event)).append('\0');
    return java.util.UUID.nameUUIDFromBytes(bytes(key.toString())).toString().toUpperCase(java.util.Locale.ROOT);
  }
  private ActivityArchiveRules(){}
}
