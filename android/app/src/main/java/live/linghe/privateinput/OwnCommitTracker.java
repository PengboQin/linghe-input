package live.linghe.privateinput;
import java.util.*;

/** Recent own commits, anchored by frontend digests; never trains arbitrary host edits. */
final class OwnCommitTracker {
 static final class Replacement {
  final String code,context,rejected,reading;final int document;final long time;
  Replacement(int doc,String code,String context,String rejected,String reading,long time){document=doc;this.code=code;this.context=context;this.rejected=rejected;this.reading=reading;this.time=time;}
  boolean current(int doc,long now,String own){return document==doc&&now>=time&&now-time<=120000&&OwnText.equal(own,context);}
 }
 private int document;private long time;private String anchor,after,remaining,original,code,context,reading;
 void invalidate(){remaining=null;}
 void stage(int document,String anchor,String after,String text,String code,String context,long time,String reading){if(anchor==null||after==null||!NineSpelling.isCode(code)||text.isEmpty()||text.length()>256){invalidate();return;}this.document=document;this.anchor=anchor;this.after=after;this.remaining=text;original=text;this.code=code;this.context=context;this.time=time;this.reading=reading;}
 String expected(int document,long now){return remaining!=null&&this.document==document&&now>=time&&now-time<=120000?remaining:null;}
 boolean anchored(int document,String anchor,String after,long now){return expected(document,now)!=null&&this.anchor.equals(anchor)&&this.after.equals(after);}
 Replacement deleted(int document,String anchor,String after,long now){if(!anchored(document,anchor,after,now)){invalidate();return null;}remaining=OwnText.dropLast(remaining);if(remaining.isEmpty()){invalidate();return new Replacement(document,code,context,original,reading,now);}return null;}
 Replacement partial(int document,String anchor,String after,long now){if(!anchored(document,anchor,after,now)||remaining.equals(original)||remaining.isEmpty()||reading==null)return null;String[] syllables=reading.toLowerCase(Locale.ROOT).trim().split("[ ']+");List<String> all=OwnText.characters(original),left=OwnText.characters(remaining);if(syllables.length!=all.size()||!code.equals(NineSpelling.encode(reading)))return null;String tail=String.join(" ",Arrays.asList(syllables).subList(left.size(),syllables.length));String tailCode=NineSpelling.encode(tail);return tailCode==null?null:new Replacement(document,tailCode,OwnText.append(remaining,context),String.join("",all.subList(left.size(),all.size())),tail,now);}
 String remainingContext(){return remaining==null?context:OwnText.append(remaining,context);}
}
