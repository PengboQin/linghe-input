package live.linghe.privateinput;

import java.io.*;import java.nio.*;import java.nio.charset.*;

/** Stream-only document boundary shared by the native picker and isolated tests. */
final class LexiconDocuments {
 static String read(InputStream input)throws IOException {
  if(input==null)throw new IOException("无法打开文件");ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buffer=new byte[8192];int count;
  while((count=input.read(buffer))!=-1){if(count==0)continue;if(bytes.size()+count>PersonalLexicon.MAX_BYTES)throw new IOException("个人词库文件过大");bytes.write(buffer,0,count);}
  return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
 }
 static void write(OutputStream output,String encoded)throws IOException {
  if(output==null)throw new IOException("无法写入文件");byte[] bytes=encoded.getBytes(StandardCharsets.UTF_8);if(bytes.length>PersonalLexicon.MAX_BYTES)throw new IOException("个人词库文件过大");output.write(bytes);output.flush();
 }
}
