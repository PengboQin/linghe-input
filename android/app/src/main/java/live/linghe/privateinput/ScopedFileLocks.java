package live.linghe.privateinput;
import java.io.*;import java.nio.channels.*;import java.nio.file.Files;import java.util.*;
/** JVM exclusion per canonical lock file, plus the existing cross-process lock. */
final class ScopedFileLocks {
 interface Work<T>{T run()throws Exception;}
 private static final Map<String,Entry> entries=new HashMap<>();
 private static final class Entry{int users,depth;Thread owner;}
 static <T>T run(File directory,String name,Work<T> action)throws Exception{
  if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法打开输入记忆目录");File path=new File(directory,name);if(Files.isSymbolicLink(path.toPath()))throw new IOException("Invalid lock file");String key=path.getCanonicalPath();Entry entry;
  synchronized(entries){entry=entries.get(key);if(entry==null){entry=new Entry();entries.put(key,entry);}entry.users++;}
  try{synchronized(entry){if(Files.isSymbolicLink(path.toPath()))throw new IOException("Invalid lock file");if(entry.owner==Thread.currentThread()){entry.depth++;try{return action.run();}finally{entry.depth--;}}
   try(RandomAccessFile holder=new RandomAccessFile(path,"rw");FileLock held=holder.getChannel().lock()){entry.owner=Thread.currentThread();entry.depth=1;try{return action.run();}finally{entry.depth=0;entry.owner=null;}}
  }}finally{synchronized(entries){if(--entry.users==0)entries.remove(key);}}
 }
 private ScopedFileLocks(){}
}
