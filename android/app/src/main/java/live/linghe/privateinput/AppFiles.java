package live.linghe.privateinput;
import android.util.AtomicFile;import java.io.*;import java.nio.*;import java.nio.charset.*;import java.nio.channels.*;import java.nio.file.Files;

/** Bounded app-private files. No external paths, UI, network, or generated identities on read. */
final class AppFiles {
 interface Work<T>{T run()throws Exception;}
 static <T>T locked(File directory,String name,Work<T> work)throws Exception {
  return ScopedFileLocks.run(directory,name,work::run);
 }
 static String read(File file,int maximum)throws IOException {
  if(Files.isSymbolicLink(file.toPath()))throw new IOException("Invalid app file");try(InputStream input=new FileInputStream(file)){return read(input,maximum);}
 }
 static String readOptional(AtomicFile file,int maximum)throws IOException {
  if(!file.getBaseFile().exists()&&!new File(file.getBaseFile()+".bak").exists())return null;
  if(Files.isSymbolicLink(file.getBaseFile().toPath()))throw new IOException("Invalid app file");try(InputStream input=file.openRead()){return read(input,maximum);}
 }
 private static String read(InputStream input,int maximum)throws IOException {
  ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buffer=new byte[65536];int count;while((count=input.read(buffer))!=-1){if(count==0)continue;if(bytes.size()+count>maximum)throw new IOException("输入记忆文件过大");bytes.write(buffer,0,count);}
  return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
 }
 static void write(AtomicFile file,String text,int maximum)throws IOException {
  byte[] bytes=text.getBytes(StandardCharsets.UTF_8);if(bytes.length>maximum)throw new IOException("输入记忆文件过大");FileOutputStream out=null;
  try{out=file.startWrite();out.write(bytes);file.finishWrite(out);}catch(Exception error){if(out!=null)file.failWrite(out);throw error;}
 }
}
