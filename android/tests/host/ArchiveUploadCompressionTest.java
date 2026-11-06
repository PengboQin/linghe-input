package live.linghe.privateinput;
import java.io.*;import java.util.*;import java.util.zip.*;import java.nio.charset.StandardCharsets;
public final class ArchiveUploadCompressionTest {
 public static void main(String[] args)throws Exception{
  byte[] original=String.join("",Collections.nCopies(256,"{\"event\":\"synthetic\",\"text\":\"合成 🦢\\n  retained\"}")).getBytes(StandardCharsets.UTF_8);
  ArchiveUploadCompression.Body body=ArchiveUploadCompression.prepare(original,true);
  if(!body.gzip||body.bytes.length>=original.length/4)throw new AssertionError("compressible envelope");
  ByteArrayOutputStream restored=new ByteArrayOutputStream();try(GZIPInputStream in=new GZIPInputStream(new ByteArrayInputStream(body.bytes))){byte[] b=new byte[1024];int n;while((n=in.read(b))!=-1)restored.write(b,0,n);}
  if(!Arrays.equals(original,restored.toByteArray()))throw new AssertionError("signed bytes changed");
  if(ArchiveUploadCompression.prepare(original,false).gzip)throw new AssertionError("not negotiated");
  if(ArchiveUploadCompression.prepare(new byte[]{123,125},true).gzip)throw new AssertionError("small request");
  byte[] random=new byte[8192];new Random(7).nextBytes(random);ArchiveUploadCompression.Body plain=ArchiveUploadCompression.prepare(random,true);
  if(plain.gzip||!Arrays.equals(plain.bytes,random))throw new AssertionError("incompressible data");
  try{ArchiveUploadCompression.prepare(new byte[1048577],true);throw new AssertionError("bound");}catch(IOException expected){}
  System.out.println("PASS gzip negotiation/roundtrip/small/incompressible/bound");
 }
}
