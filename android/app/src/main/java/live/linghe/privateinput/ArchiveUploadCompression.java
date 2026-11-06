package live.linghe.privateinput;
import java.io.*;import java.util.zip.GZIPOutputStream;

/** Compress only the transport envelope; signatures/events are immutable. */
final class ArchiveUploadCompression {
 static final class Body {final byte[] bytes;final boolean gzip;Body(byte[] bytes,boolean gzip){this.bytes=bytes;this.gzip=gzip;}}
 static Body prepare(byte[] input,boolean negotiated)throws IOException{
  if(input.length>1048576)throw new IOException("归档请求超限");
  if(!negotiated||input.length<4096)return new Body(input,false);
  ByteArrayOutputStream output=new ByteArrayOutputStream();
  try(GZIPOutputStream stream=new GZIPOutputStream(output)){stream.write(input);}
  byte[] compressed=output.toByteArray();return compressed.length+32<input.length?new Body(compressed,true):new Body(input,false);
 }
 private ArchiveUploadCompression(){}
}
