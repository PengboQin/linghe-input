package live.linghe.privateinput;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;

/** Volatile UI value only. Preview is lossy; the accepted payload never is. */
final class ClipboardCandidateState {
 static final class Value {
  final String id,raw,preview;final boolean received;
  private Value(String id,String raw,String preview,boolean received){this.id=id;this.raw=raw;this.preview=preview;this.received=received;}
  static Value create(String raw,long timestamp){
   return create(raw,timestamp,false);
  }
  static Value create(String raw,long timestamp,boolean received){
   if(raw==null||raw.isEmpty()||raw.indexOf('\0')>=0||raw.codePoints().allMatch(c->Character.isWhitespace(c)||Character.isSpaceChar(c)||c==0x85))return null;
   int bytes=ActivityArchiveRules.utf8Length(raw);if(bytes<0||bytes>65536)return null;
   try{
    byte[] hash=MessageDigest.getInstance("SHA-256").digest(raw.getBytes(StandardCharsets.UTF_8));StringBuilder identity=new StringBuilder("clipboard:").append(timestamp).append(':');for(byte b:hash)identity.append(String.format(Locale.ROOT,"%02x",b&255));
    String flat=raw.replaceAll("\\s+"," ").trim();int end=flat.offsetByCodePoints(0,Math.min(24,flat.codePointCount(0,flat.length())));String preview=flat.substring(0,end)+(end<flat.length()?"…":"");
    return new Value(identity.toString(),raw,"剪贴板 · "+preview,received);
   }catch(java.security.NoSuchAlgorithmException impossible){throw new AssertionError(impossible);}
  }
 }
 private int document=-1;private Value value;private String consumed="";
 void bind(int next){if(document!=next){document=next;value=null;}}
 boolean offer(int target,Value next){bind(target);boolean changed=value==null?next!=null:next==null||!value.id.equals(next.id);value=next;return changed;}
 Value visible(int target,boolean idle,boolean deletionLocked){return document==target&&idle&&!deletionLocked&&value!=null&&!value.id.equals(consumed)?value:null;}
 boolean matches(int target,String id){return document==target&&value!=null&&value.id.equals(id)&&!id.equals(consumed);}
 void consume(int target,String id){if(matches(target,id))consumed=id;}
 void dismiss(int target){if(document==target&&value!=null)consumed=value.id;}
}
