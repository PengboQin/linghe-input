package live.linghe.privateinput;

import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;

/** Packaged PUBLIC resources only; call on the engine worker before first create.
 * Never receives Rime userdb/Shared paths. Fixed rime-v2 target, short-lived stage
 * and backup, with a recovery point between the two directory renames.
 */
final class RimeResourceInstaller {
 interface Assets { String[] list(String path)throws IOException; InputStream open(String path)throws IOException; }
 interface Faults { void at(String point)throws IOException; }
 static final class Result {
  final File directory;final String installedDigest;final boolean upgraded;final IOException deferredFailure;
  Result(File folder,String digest,boolean changed,IOException failure){directory=folder;installedDigest=digest;upgraded=changed;deferredFailure=failure;}
 }
 private static final String TARGET="rime-v2",STAGE="rime-v2.assets-stage",BACKUP="rime-v2.assets-backup",OWNER=".assets-installer-owner-v1",MAGIC="Linghe/public-rime-assets/v1\n";
 private static final int MAX_FILES=4096,MAX_SOURCE=1024*1024;
 private static final long MAX_TOTAL=256L*1024*1024;
 private static final Faults NONE=point->{};
 private RimeResourceInstaller(){}
 static Result prepare(File files,Assets assets)throws IOException{return prepare(files,assets,NONE);}
 static synchronized Result prepare(File files,Assets assets,Faults faults)throws IOException {
  if(files==null||assets==null||faults==null)throw new IOException("resource installer arguments");
  File parent=files.getCanonicalFile();if(!parent.isDirectory())throw new IOException("resource parent missing");
  File target=new File(parent,TARGET),stage=new File(parent,STAGE),backup=new File(parent,BACKUP);
  requireDirect(parent,target);requireDirect(parent,stage);requireDirect(parent,backup);
  File lock=new File(parent,"rime-assets-install-v1.lock");requireDirect(parent,lock);
  try(RandomAccessFile handle=new RandomAccessFile(lock,"rw");FileChannel channel=handle.getChannel();FileLock ignored=channel.lock()){
   final String wanted;Set<String> inventory=new HashSet<>();
   try{
    recover(parent,target,stage,backup);
    wanted=sha(readBounded(assets.open("rime/SOURCE.json"),MAX_SOURCE));
   }catch(IOException failure){if(usable(target))return new Result(target,marker(target),false,failure);throw failure;}
   if(current(target,wanted))return new Result(target,wanted,false,null);
   boolean previous=usable(target);String oldDigest=marker(target);
   try {
    collect(assets,"rime","",inventory);
    if(!inventory.contains("SOURCE.json")||!inventory.contains("build/private_pinyin.table.bin"))throw new IOException("packaged resource inventory");
    if(stage.exists())removeOwned(parent,stage);
    if(backup.exists())throw new IOException("resource backup still retained");
    if(!stage.mkdir())throw new IOException("resource stage create");
    write(new File(stage,OWNER),(MAGIC+parent.getPath()).getBytes("UTF-8"));
    long total=0;List<String> ordered=new ArrayList<>(inventory);Collections.sort(ordered);
    for(String relative:ordered){
     faults.at("copy:"+relative);File output=child(stage,relative);File directory=output.getParentFile();
     if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("resource stage directory");
     MessageDigest checksum=digest();long bytes=0;
     try(InputStream in=assets.open("rime/"+relative);FileOutputStream out=new FileOutputStream(output)){
      byte[] buffer=new byte[65536];int n;
      while((n=in.read(buffer))!=-1){if(n==0)continue;bytes+=n;total+=n;if(total>MAX_TOTAL)throw new IOException("resource size limit");checksum.update(buffer,0,n);out.write(buffer,0,n);}out.getFD().sync();
     }
     if(bytes!=output.length()||!hex(checksum.digest()).equals(sha(output)))throw new IOException("resource copy verification");
    }
    if(!wanted.equals(sha(new File(stage,"SOURCE.json"))))throw new IOException("resource source changed during copy");
    write(new File(stage,"ready"),(wanted+"\n").getBytes("US-ASCII"));
    if(!current(stage,wanted))throw new IOException("resource incomplete stage");
    faults.at("before-old-rename");
    if(target.exists()){
     // rime-v2 has always been this app's unpacked PUBLIC asset tree. Refuse
     // mixed/user data or symbolic links rather than moving/deleting them.
     publicTree(target,inventory);write(new File(target,OWNER),(MAGIC+parent.getPath()).getBytes("UTF-8"));
     if(!target.renameTo(backup))throw new IOException("resource old rename");
    }
    faults.at("after-old-rename");
    if(!stage.renameTo(target))throw new IOException("resource promote");
    // A simulated process death here leaves a complete new target plus old
    // backup; next initialization verifies the new ready marker and cleans it.
    faults.at("after-promote");
    IOException cleanup=null;try{if(backup.exists())removeOwned(parent,backup);}catch(IOException problem){cleanup=problem;}
    return new Result(target,wanted,true,cleanup);
   }catch(IOException failure){
    if(!target.exists()&&backup.exists()&&owned(parent,backup)){
     if(!backup.renameTo(target))throw new IOException("resource rollback failed; old public backup retained",failure);
    }
    // A complete promoted version remains usable if only cleanup failed.
    if(current(target,wanted))return new Result(target,wanted,true,failure);
    try{if(stage.exists())removeOwned(parent,stage);}catch(IOException retained){failure.addSuppressed(retained);}
    if(previous&&usable(target))return new Result(target,oldDigest,false,failure);
    throw failure;
   }
  }
 }
 private static void recover(File parent,File target,File stage,File backup)throws IOException {
  if(backup.exists()){
   if(!owned(parent,backup))throw new IOException("unowned resource backup");
   if(!target.exists()){
    if(!backup.renameTo(target))throw new IOException("resource interrupted rollback");
   }else if(owned(parent,target)&&marker(target).matches("[0-9a-f]{64}")&&current(target,marker(target)))removeOwned(parent,backup);
   else throw new IOException("resource ambiguous recovery; backup preserved");
  }
  if(stage.exists())removeOwned(parent,stage);
 }
 private static void collect(Assets assets,String path,String relative,Set<String> result)throws IOException {
  String[] names=assets.list(path);
  if(names==null||names.length==0){if(relative.isEmpty())throw new IOException("empty resource package");if(!result.add(relative)||result.size()>MAX_FILES)throw new IOException("resource file limit");return;}
  for(String name:names){safeName(name);if(name.equals("ready")||name.equals(OWNER))throw new IOException("reserved resource asset");collect(assets,path+"/"+name,relative.isEmpty()?name:relative+"/"+name,result);}
 }
 private static void publicTree(File folder,Set<String> allowed)throws IOException {publicTree(folder,folder,allowed);}
 private static void publicTree(File root,File item,Set<String> allowed)throws IOException {
  if(Files.isSymbolicLink(item.toPath()))throw new IOException("resource symlink refused");
  if(item.isDirectory()){File[] children=item.listFiles();if(children==null)throw new IOException("resource tree listing");for(File child:children)publicTree(root,child,allowed);return;}
  String relative=root.toPath().relativize(item.toPath()).toString().replace(File.separatorChar,'/');
  if(!relative.equals("ready")&&!relative.equals(OWNER)&&!allowed.contains(relative))throw new IOException("unrecognized data in public resource tree; preserved");
 }
 private static boolean usable(File folder)throws IOException {
  if(!folder.isDirectory()||Files.isSymbolicLink(folder.toPath()))return false;
  for(String name:new String[]{"ready","SOURCE.json","build/private_pinyin.table.bin","build/private_pinyin.schema.yaml","build/private_nine.schema.yaml"}){
   File file=child(folder,name);if(!file.isFile()||(!name.equals("ready")&&file.length()==0))return false;
  }
  return true;
 }
 private static boolean current(File folder,String expected)throws IOException {
  return usable(folder)&&expected.equals(marker(folder))&&expected.equals(sha(new File(folder,"SOURCE.json")));
 }
 private static String marker(File folder)throws IOException {
  File file=new File(folder,"ready");if(!file.isFile())return "";
  return new String(readBounded(new FileInputStream(file),128),"US-ASCII").trim();
 }
 private static boolean owned(File parent,File folder)throws IOException {
  if(!folder.isDirectory()||Files.isSymbolicLink(folder.toPath()))return false;
  File marker=new File(folder,OWNER);if(!marker.isFile()||Files.isSymbolicLink(marker.toPath()))return false;
  return new String(readBounded(new FileInputStream(marker),4096),"UTF-8").equals(MAGIC+parent.getPath());
 }
 private static void removeOwned(File parent,File folder)throws IOException {
  if(!owned(parent,folder))throw new IOException("unowned resource temporary tree preserved");
  noLinks(folder);removeTree(folder);
 }
 private static void noLinks(File file)throws IOException {
  if(Files.isSymbolicLink(file.toPath()))throw new IOException("resource temporary symlink preserved");
  if(file.isDirectory()){File[] list=file.listFiles();if(list==null)throw new IOException("resource temporary listing");for(File child:list)noLinks(child);}
 }
 private static void removeTree(File file)throws IOException {
  if(file.isDirectory()){File[] list=file.listFiles();if(list==null)throw new IOException("resource cleanup listing");for(File child:list)removeTree(child);}
  if(!file.delete())throw new IOException("resource cleanup retained");
 }
 private static File child(File root,String relative)throws IOException {
  String[] names=relative.split("/",-1);File value=root;for(String name:names){safeName(name);value=new File(value,name);if(Files.isSymbolicLink(value.toPath()))throw new IOException("resource symlink refused");}
  if(!value.getCanonicalPath().startsWith(root.getCanonicalPath()+File.separator))throw new IOException("resource path escaped");return value;
 }
 private static void safeName(String name)throws IOException {if(name==null||name.isEmpty()||name.equals(".")||name.equals("..")||name.indexOf('/')>=0||name.indexOf('\\')>=0||!name.matches("[A-Za-z0-9._-]+"))throw new IOException("resource name");}
 private static void requireDirect(File parent,File value)throws IOException {if(Files.isSymbolicLink(value.toPath())||!value.getCanonicalFile().getParentFile().equals(parent))throw new IOException("resource direct path");}
 private static void write(File file,byte[] bytes)throws IOException {try(FileOutputStream out=new FileOutputStream(file)){out.write(bytes);out.getFD().sync();}}
 private static byte[] readBounded(InputStream stream,int limit)throws IOException {
  try(InputStream in=stream;ByteArrayOutputStream out=new ByteArrayOutputStream()){
   byte[] buffer=new byte[8192];int n;while((n=in.read(buffer))!=-1){if(n==0)continue;if(out.size()+n>limit)throw new IOException("resource metadata size");out.write(buffer,0,n);}return out.toByteArray();
  }
 }
 private static MessageDigest digest()throws IOException {try{return MessageDigest.getInstance("SHA-256");}catch(java.security.NoSuchAlgorithmException unavailable){throw new IOException(unavailable);}}
 private static String sha(byte[] bytes)throws IOException{return hex(digest().digest(bytes));}
 private static String sha(File file)throws IOException {MessageDigest digest=digest();try(InputStream in=new FileInputStream(file)){byte[] buffer=new byte[65536];int n;while((n=in.read(buffer))!=-1)if(n>0)digest.update(buffer,0,n);}return hex(digest.digest());}
 private static String hex(byte[] bytes){StringBuilder value=new StringBuilder();for(byte b:bytes)value.append(String.format(Locale.ROOT,"%02x",b&255));return value.toString();}
}
