package live.linghe.privateinput;

import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class RimeResourceInstallerTest {
 static int checks;
 static void check(boolean ok,String name){if(!ok)throw new AssertionError(name);checks++;}
 static final class Assets implements RimeResourceInstaller.Assets {
  final TreeMap<String,byte[]> files=new TreeMap<>();int lists,opens;String fail;boolean changingSource;int sourceOpens;
  Assets(String version){put("SOURCE.json","{\"version\":\""+version+"\"}");put("build/private_pinyin.table.bin","table-"+version);put("build/private_pinyin.schema.yaml","pinyin-"+version);put("build/private_nine.schema.yaml","nine-"+version);put("private_pinyin.dict.yaml","dict-"+version);put("charset/standard-8105.txt","规范");}
  void put(String path,String value){try{files.put(path,value.getBytes("UTF-8"));}catch(Exception e){throw new AssertionError(e);}}
  public String[] list(String path)throws IOException{lists++;if(path.equals(fail))throw new IOException("synthetic list failure");String prefix=path.equals("rime")?"":path.substring(5)+"/";Set<String> out=new TreeSet<>();for(String key:files.keySet())if(key.startsWith(prefix)){String suffix=key.substring(prefix.length());out.add(suffix.split("/",2)[0]);}return out.toArray(new String[0]);}
  public InputStream open(String path)throws IOException{opens++;if(path.equals(fail))throw new IOException("synthetic asset read failure");byte[] value=files.get(path.substring(5));if(value==null)throw new FileNotFoundException(path);if(path.equals("rime/SOURCE.json")&&changingSource&&++sourceOpens>1)value="changed".getBytes("UTF-8");return new ByteArrayInputStream(value);}
 }
 static File root()throws Exception{File root=Files.createTempDirectory("linghe-public-assets-").toFile();new File(root,"Rime").mkdir();new File(root,"Shared").mkdir();write(new File(root,"Rime/user.userdb"),"USER-DATABASE");write(new File(root,"Shared/learning-v1.json"),"PRIVATE-LEARNING");return root;}
 static void write(File path,String value)throws Exception{path.getParentFile().mkdirs();Files.write(path.toPath(),value.getBytes("UTF-8"));}
 static String text(File path)throws Exception{return new String(Files.readAllBytes(path.toPath()),"UTF-8");}
 static String sha(byte[] value)throws Exception{StringBuilder out=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(value))out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();}
 static void privateUnchanged(File root)throws Exception{check(text(new File(root,"Rime/user.userdb")).equals("USER-DATABASE")&&text(new File(root,"Shared/learning-v1.json")).equals("PRIVATE-LEARNING"),"private data unchanged");}
 static void noTemporary(File root){check(!new File(root,"rime-v2.assets-stage").exists()&&!new File(root,"rime-v2.assets-backup").exists(),"no duplicate public tree retained");}
 static void cleanup(File file)throws Exception{if(!Files.isSymbolicLink(file.toPath())&&file.isDirectory()){File[] children=file.listFiles();if(children!=null)for(File child:children)cleanup(child);}Files.deleteIfExists(file.toPath());}
 static void installed(File root,String version)throws Exception{check(text(new File(root,"rime-v2/build/private_pinyin.table.bin")).equals("table-"+version),"installed "+version);privateUnchanged(root);}
 static final class Death extends Error{}
 public static void main(String[] args)throws Exception{
  File root=root();try{
   Assets one=new Assets("one");RimeResourceInstaller.Result result=RimeResourceInstaller.prepare(root,one);
   check(result.upgraded&&result.deferredFailure==null,"initial complete install");check(result.installedDigest.equals(sha(one.files.get("SOURCE.json"))),"SOURCE SHA marker");installed(root,"one");noTemporary(root);
   Assets same=new Assets("one");long before=new File(root,"rime-v2/ready").lastModified();result=RimeResourceInstaller.prepare(root,same);
   check(!result.upgraded&&same.opens==1&&same.lists==0,"same version reads only small SOURCE metadata");check(new File(root,"rime-v2/ready").lastModified()==before,"same version no output rewrite");
   write(new File(root,"rime-v2/ready"),"");result=RimeResourceInstaller.prepare(root,new Assets("two"));check(result.upgraded,"legacy empty ready migrates");installed(root,"two");noTemporary(root);
  }finally{cleanup(root);}
  for(String point:new String[]{"copy:build/private_pinyin.table.bin","before-old-rename","after-old-rename"}){
   root=root();try{RimeResourceInstaller.prepare(root,new Assets("old"));RimeResourceInstaller.Result result=RimeResourceInstaller.prepare(root,new Assets("new"),name->{if(name.equals(point))throw new IOException("synthetic "+point);});check(!result.upgraded&&result.deferredFailure!=null,"failed upgrade reports deferred "+point);installed(root,"old");noTemporary(root);}finally{cleanup(root);}
  }
  for(String point:new String[]{"after-old-rename","after-promote"}){
   root=root();try{
    RimeResourceInstaller.prepare(root,new Assets("old"));boolean dead=false;try{RimeResourceInstaller.prepare(root,new Assets("new"),name->{if(name.equals(point))throw new Death();});}catch(Death expected){dead=true;}
    check(dead,"simulated process death "+point);check(new File(root,"rime-v2.assets-backup").isDirectory(),"old backup retained at death");RimeResourceInstaller.prepare(root,new Assets("new"));installed(root,"new");noTemporary(root);
   }finally{cleanup(root);}
  }
  root=root();try{
   RimeResourceInstaller.prepare(root,new Assets("old"));Assets broken=new Assets("new");broken.fail="rime/SOURCE.json";RimeResourceInstaller.Result result=RimeResourceInstaller.prepare(root,broken);check(!result.upgraded&&result.deferredFailure!=null,"unreadable SOURCE falls back");installed(root,"old");
   broken=new Assets("new");broken.fail="rime/build/private_pinyin.table.bin";result=RimeResourceInstaller.prepare(root,broken);check(!result.upgraded,"asset read failure falls back");installed(root,"old");noTemporary(root);
   broken=new Assets("new");broken.changingSource=true;result=RimeResourceInstaller.prepare(root,broken);check(!result.upgraded&&result.deferredFailure!=null,"changing source rejected before promote");installed(root,"old");noTemporary(root);
   write(new File(root,"rime-v2/private-user.sqlite"),"DO NOT TOUCH");result=RimeResourceInstaller.prepare(root,new Assets("new"));check(!result.upgraded&&text(new File(root,"rime-v2/private-user.sqlite")).equals("DO NOT TOUCH"),"unexpected mixed data retained and upgrade deferred");installed(root,"old");noTemporary(root);
  }finally{cleanup(root);}
  root=root();try{
   RimeResourceInstaller.prepare(root,new Assets("old"));File stage=new File(root,"rime-v2.assets-stage");write(new File(stage,"unowned.txt"),"NOT INSTALLER DATA");RimeResourceInstaller.Result result=RimeResourceInstaller.prepare(root,new Assets("new"));check(!result.upgraded&&text(new File(stage,"unowned.txt")).equals("NOT INSTALLER DATA"),"unowned temporary tree never removed");installed(root,"old");
  }finally{cleanup(root);}
  root=root();try{
   RimeResourceInstaller.prepare(root,new Assets("old"));File stage=new File(root,"rime-v2.assets-stage");stage.mkdir();write(new File(stage,".assets-installer-owner-v1"),"Linghe/public-rime-assets/v1\n"+root.getCanonicalPath());Files.createSymbolicLink(new File(stage,"escape").toPath(),new File(root,"Rime/user.userdb").toPath());RimeResourceInstaller.Result result=RimeResourceInstaller.prepare(root,new Assets("new"));check(!result.upgraded&&Files.isSymbolicLink(new File(stage,"escape").toPath()),"symlink temporary tree preserved");installed(root,"old");
  }finally{cleanup(root);}
  root=root();try{
   Assets broken=new Assets("first");broken.fail="rime/build/private_pinyin.table.bin";boolean failed=false;try{RimeResourceInstaller.prepare(root,broken);}catch(IOException expected){failed=true;}check(failed&&!new File(root,"rime-v2/ready").exists(),"first-install failure never advertises ready");privateUnchanged(root);noTemporary(root);
  }finally{cleanup(root);}
  root=root();try{
   RimeResourceInstaller.prepare(root,new Assets("old"));final File sharedRoot=root;AtomicInteger upgraded=new AtomicInteger();ExecutorService workers=Executors.newFixedThreadPool(2);
   try{Future<?> a=workers.submit(()->{try{if(RimeResourceInstaller.prepare(sharedRoot,new Assets("new")).upgraded)upgraded.incrementAndGet();}catch(Exception e){throw new RuntimeException(e);}});Future<?> b=workers.submit(()->{try{if(RimeResourceInstaller.prepare(sharedRoot,new Assets("new")).upgraded)upgraded.incrementAndGet();}catch(Exception e){throw new RuntimeException(e);}});a.get(5,TimeUnit.SECONDS);b.get(5,TimeUnit.SECONDS);check(upgraded.get()==1,"two background owners serialize one promotion");installed(root,"new");noTemporary(root);}finally{workers.shutdownNow();}
  }finally{cleanup(root);}
  System.out.println("PASS "+checks+" filesystem assertions; no Android host/user/network required");
 }
}
