package live.linghe.privateinput;
import android.content.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
/** A durable barrier; only confirmed departure/expiry requests it, never upgrade. */
final class PersonalReset {
  interface Handler {void reset(CountDownLatch done,Exception[] failure);}
  static volatile Handler liveKeyboard;
  static String generation(Context c){return c.getSharedPreferences("privacy-reset",0).getString("generation","initial");}
  static String fileGeneration(File directory){try{File f=new File(directory,"privacy-reset-generation-v1.txt");return f.isFile()?new String(java.nio.file.Files.readAllBytes(f.toPath()),java.nio.charset.StandardCharsets.UTF_8):"initial";}catch(Exception e){return "unavailable";}}
  static boolean expired(Context c){long expiry=c.getSharedPreferences("sync-consent",0).getLong("expires",0);return expiry>0&&System.currentTimeMillis()/1000>=expiry;}
  static void request(Context c,String reason)throws Exception{
    c.getSharedPreferences("privacy-reset",0).edit().putString("generation",UUID.randomUUID().toString()).putString("reason",reason).putBoolean("pending",true).commit();
    ActivityArchiveManager.get(c).pauseForDeparture();
    c.getSharedPreferences("sync-consent",0).edit().putLong("generation",c.getSharedPreferences("sync-consent",0).getLong("generation",0)+1).putBoolean("learning",false).putBoolean("clipboard",false).putLong("expires",0).commit();
    try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(c.getFilesDir(),"privacy-reset-generation-v1.txt"))){out.write(generation(c).getBytes(java.nio.charset.StandardCharsets.UTF_8));out.getFD().sync();}
    File shared=new File(c.getFilesDir(),"Shared");shared.mkdirs();try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(shared,"privacy-reset-generation-v1.txt"))){out.write(generation(c).getBytes(java.nio.charset.StandardCharsets.UTF_8));out.getFD().sync();}
    Handler handler=liveKeyboard;
    if(handler==null){apply(c);return;}
    CountDownLatch done=new CountDownLatch(1);Exception[] error=new Exception[1];handler.reset(done,error);
    if(!done.await(10,TimeUnit.SECONDS))throw new IOException("正在清除个人资料，请稍后重试");
    if(error[0]!=null)throw error[0];
  }
  static void deadline(Context c)throws Exception {
    long expiry=c.getSharedPreferences("sync-consent",0).getLong("expires",0);
    if(expiry>0&&System.currentTimeMillis()/1000>=expiry)request(c,"inactive");
  }
  static void apply(Context c)throws Exception {
    if(!c.getSharedPreferences("privacy-reset",0).getBoolean("pending",false))return;
    ArrayList<String> personalFiles=new ArrayList<>(Arrays.asList("Rime","Shared","ClipboardOnce","nine-choice-memory-v1.json","nine-choice-memory-v2.json","nine-choice-memory-v3.json","learning-checkpoint-v1.json","learning-import-pending-v1.json","learning-maintenance-dirty-v1","local-replica-id.txt","delivery-backup"));ClipboardLiveStore.resetForDeparture(c);RecentLearningStore.clearForDeparture(c.getFilesDir());for(String name:personalFiles)for(String suffix:new String[]{"",".bak",".new"})remove(new File(c.getFilesDir(),name+suffix));
    File shared=new File(c.getFilesDir(),"Shared");shared.mkdirs();try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(shared,"privacy-reset-generation-v1.txt"))){out.write(generation(c).getBytes(java.nio.charset.StandardCharsets.UTF_8));out.getFD().sync();}
    remove(c.getCacheDir());c.getCacheDir().mkdirs();
    android.content.SharedPreferences p=c.getSharedPreferences("keyboard",0);android.content.SharedPreferences.Editor edit=p.edit();
    for(String key:p.getAll().keySet())if(key.startsWith("symbol-use-"))edit.remove(key);edit.commit();
    c.getSharedPreferences("privacy-reset",0).edit().putBoolean("pending",false).commit();
  }
  private static void remove(File f)throws IOException {
    if(!f.exists()&&!java.nio.file.Files.isSymbolicLink(f.toPath()))return;
    if(f.isDirectory()&&!java.nio.file.Files.isSymbolicLink(f.toPath())){File[] children=f.listFiles();if(children==null)throw new IOException("无法清除个人资料");for(File child:children)remove(child);}
    if(!f.delete())throw new IOException("个人资料清理未完成，将在下次继续");
  }
}
