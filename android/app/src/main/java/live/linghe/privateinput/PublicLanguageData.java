package live.linghe.privateinput;
import java.io.*;import java.nio.*;import java.nio.channels.*;import java.nio.charset.*;import java.util.*;

/** Same immutable little-endian frequency and continuation indexes as iOS. */
final class PublicLanguageData {
 private static ByteBuffer map(File file,String magic,int stride,int maximum)throws IOException{try(FileInputStream in=new FileInputStream(file)){long size=in.getChannel().size();if(size<16||size>8*1024*1024)throw new IOException("index size");ByteBuffer b=in.getChannel().map(FileChannel.MapMode.READ_ONLY,0,size).order(ByteOrder.LITTLE_ENDIAN);byte[] header=new byte[8];b.get(header);if(!new String(header,StandardCharsets.US_ASCII).equals(magic)||b.getInt(12)!=stride||b.getInt(8)<0||b.getInt(8)>maximum||16L+(long)b.getInt(8)*stride>size)throw new IOException("index header");return b;}}
 static final class Nine {
  private final ByteBuffer data;private final int count;
  Nine(File file)throws IOException{data=map(file,"PI9LEX01",12,300000);count=data.getInt(8);if(data.limit()!=16+count*12)throw new IOException("index length");}
  static final class Completion {final String input;final long frequency;Completion(String input,long frequency){this.input=input;this.frequency=frequency;}}
  private long key(String code){long value=0;for(char c:code.toCharArray())value=(value<<3)|(c-'2');return ((long)code.length()<<54)|value;}
  private int lowerBound(long key){int low=0,high=count;while(low<high){int mid=(low+high)/2;if(data.getLong(16+mid*12)<key)low=mid+1;else high=mid;}return low;}
  List<Completion> completions(String prefix,int limit,int maxAdditionalKeys){
   if(!prefix.matches("[2-9]{3,12}")||limit<=0||maxAdditionalKeys<=0)return Collections.emptyList();
   ArrayList<Completion> result=new ArrayList<>();
   for(int length=prefix.length()+1;length<=Math.min(18,prefix.length()+Math.min(4,maxAdditionalKeys));length++){
    int extra=length-prefix.length();long low=key(prefix+String.join("",Collections.nCopies(extra,"2"))),high=key(prefix+String.join("",Collections.nCopies(extra,"9")));
    for(int index=lowerBound(low);index<count;index++){
     long value=data.getLong(16+index*12);if(value>high)break;
     StringBuilder code=new StringBuilder();for(int digit=length-1;digit>=0;digit--)code.append((char)('2'+((value>>>(digit*3))&7)));
     result.add(new Completion(code.toString(),Integer.toUnsignedLong(data.getInt(24+index*12))));
    }
   }
   result.sort((a,b)->{int comparison=Long.compare(b.frequency,a.frequency);if(comparison!=0)return comparison;comparison=Integer.compare(a.input.length(),b.input.length());return comparison!=0?comparison:a.input.compareTo(b.input);});
   return new ArrayList<>(result.subList(0,Math.min(result.size(),Math.min(limit,16))));
  }
  long frequency(String code){if(!code.matches("[2-9]{1,18}"))return 0;long key=0;for(char c:code.toCharArray())key=(key<<3)|(c-'2');key|=(long)code.length()<<54;int lo=0,hi=count;while(lo<hi){int mid=(lo+hi)/2;if(data.getLong(16+mid*12)<key)lo=mid+1;else hi=mid;}return lo<count&&data.getLong(16+lo*12)==key?Integer.toUnsignedLong(data.getInt(24+lo*12)):0;}
 }
 static final class Suggestion {final String text;final double score;Suggestion(String t,double s){text=t;score=s;}}
 static final class Continuations {
  private final ByteBuffer data;private final int count,strings;
  Continuations(File file)throws IOException{data=map(file,"PINEXT01",20,300000);count=data.getInt(8);strings=16+count*20;}
  private long key(String text){int[] chars=text.codePoints().toArray();if(chars.length<1||chars.length>3)return -1;long result=(long)chars.length<<48;for(int cp:chars){if(cp<0x4e00||cp>0x9fff)return -1;result=(result&0xffff000000000000L)|((result&0x0000ffffffffffffL)<<16)|cp;}return result;}
  List<Suggestion> suggestions(String context,int limit){if(context.isEmpty()||context.endsWith("\n")||limit<=0)return Collections.emptyList();String trimmed=context;String trailing="，,。.!！？?；;：:、 ”\"’'";while(!trimmed.isEmpty()&&trailing.indexOf(trimmed.charAt(trimmed.length()-1))>=0)trimmed=trimmed.substring(0,trimmed.length()-1);int start=trimmed.length();while(start>0&&Character.isLetter(trimmed.codePointBefore(start)))start-=Character.charCount(trimmed.codePointBefore(start));String scope=trimmed.substring(start);int chars=scope.codePointCount(0,scope.length());if(chars>3)scope=scope.substring(scope.offsetByCodePoints(0,chars-3));if(key(scope)<0)return Collections.emptyList();Map<String,Double> scores=new HashMap<>();
   for(int size=scope.length();size>=1;size--){long k=key(scope.substring(scope.length()-size));if(k<0)continue;int lo=0,hi=count;while(lo<hi){int mid=(lo+hi)/2;if(data.getLong(16+mid*20)<k)lo=mid+1;else hi=mid;}while(lo<count&&data.getLong(16+lo*20)==k){int base=16+lo*20;long offset=Integer.toUnsignedLong(data.getInt(base+8));int length=Short.toUnsignedInt(data.getShort(base+12));long freq=Integer.toUnsignedLong(data.getInt(base+16));if(length>0&&length<=12&&strings+offset+length<=data.limit()){byte[] bytes=new byte[length];ByteBuffer view=data.duplicate();view.position((int)(strings+offset));view.get(bytes);try{String word=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();if(word.codePoints().allMatch(Character::isLetter))scores.merge(word,size*.7+Math.log1p(freq)*.08,Math::max);}catch(CharacterCodingException ignored){}}lo++;}}
   char last=context.charAt(context.length()-1);if("，,；;：:".indexOf(last)>=0){String clause=context.substring(context.offsetByCodePoints(0,Math.max(0,context.codePointCount(0,context.length())-64)));String[] links=clause.contains("如果")?new String[]{"就","可以","那么"}:clause.contains("因为")?new String[]{"所以","我们","就"}:clause.contains("虽然")?new String[]{"但是","不过","还是"}:new String[]{"然后","我们","可以","不过"};for(int i=0;i<links.length;i++)scores.merge(links[i],3-i*.2,Math::max);}else if("。.!！？?".indexOf(last)>=0){String[] links={"另外","我们","我","然后"};for(int i=0;i<links.length;i++)scores.merge(links[i],2.2-i*.2,Math::max);}
   ArrayList<Suggestion> result=new ArrayList<>();for(Map.Entry<String,Double> value:scores.entrySet())result.add(new Suggestion(value.getKey(),value.getValue()));result.sort((a,b)->{int c=Double.compare(b.score,a.score);return c!=0?c:a.text.compareTo(b.text);});return new ArrayList<>(result.subList(0,Math.min(result.size(),Math.min(limit,24))));
  }
  double affinity(String before,String text,String after){double score=0;for(Suggestion value:suggestions(before,24))if(text.startsWith(value.text))score=Math.max(score,Math.min(2,value.score*.4));if(!after.isEmpty())for(Suggestion value:suggestions(before+text,24))if(after.startsWith(value.text))score+=Math.min(1,value.score*.2);return score;}
 }
}
