package live.linghe.privateinput;
import android.view.inputmethod.EditorInfo;import android.text.InputType;import java.io.*;import java.nio.charset.StandardCharsets;import java.nio.file.Files;import java.util.*;

/** Same production service, fresh test-only files, and an own-host-only boundary. */
public final class LearningAcceptanceService extends LingheInputService {
 static volatile LearningAcceptanceService active;
 static final java.util.concurrent.CountDownLatch optionalEntered=new java.util.concurrent.CountDownLatch(1),optionalRelease=new java.util.concurrent.CountDownLatch(1);
 @Override public void onCreate(){active=this;super.onCreate();}
 @Override public void onDestroy(){super.onDestroy();if(active==this)active=null;}
 private String nonce;
 @Override protected void beforeEngineStage(String phase)throws IOException {
  android.content.SharedPreferences fixture=getSharedPreferences("startup-fixture",0);
  if(phase.equals("native")&&fixture.getBoolean("fail-native-once",false)){fixture.edit().remove("fail-native-once").commit();throw new IOException("synthetic native initialization failure");}
  if(phase.equals("optional-language")&&fixture.getBoolean("fail-optional",false)){optionalEntered.countDown();try{optionalRelease.await(10,java.util.concurrent.TimeUnit.SECONDS);}catch(InterruptedException interrupted){Thread.currentThread().interrupt();}throw new IOException("synthetic optional model failure");}
 }

 private void trace(String event,boolean restarting){try{java.lang.reflect.Field f=LingheInputService.class.getDeclaredField("snapshot");f.setAccessible(true);String[][] state=(String[][])f.get(this);java.lang.reflect.Field d=LingheInputService.class.getDeclaredField("document");d.setAccessible(true);org.json.JSONObject row=new org.json.JSONObject().put("event",event).put("ms",android.os.SystemClock.elapsedRealtime()).put("restart",restarting).put("document",d.getInt(this)).put("rawLength",state[0][2].length()).put("viewShown",isInputViewShown());File file=new File(getFilesDir().getParentFile(),"lifecycle.jsonl");if(file.length()<128*1024)try(OutputStream out=new FileOutputStream(file,true)){out.write((row.toString()+"\n").getBytes(StandardCharsets.UTF_8));}}catch(Exception ignored){}}
 @Override public void onStartInputView(EditorInfo info,boolean restarting){trace("startView-before",restarting);super.onStartInputView(info,restarting);trace("startView-after",restarting);}
 @Override public void onFinishInputView(boolean finishing){trace("finishView-before",finishing);super.onFinishInputView(finishing);trace("finishView-after",finishing);}
 @Override public void onFinishInput(){trace("finishInput-before",false);super.onFinishInput();trace("finishInput-after",false);}
 @Override public boolean onKeyDown(int key,android.view.KeyEvent event){if(key==4)trace("backDown-before",false);boolean handled=super.onKeyDown(key,event);if(key==4)trace("backDown-after-"+handled,false);return handled;}
 @Override public boolean onKeyUp(int key,android.view.KeyEvent event){if(key==4)trace("backUp-before",false);boolean handled=super.onKeyUp(key,event);if(key==4)trace("backUp-after-"+handled,false);return handled;}

 @Override public File getFilesDir(){try{if(nonce==null)nonce=UUID.fromString(getSharedPreferences("typing-host",0).getString("fixture","")).toString();File root=new File(super.getCacheDir(),"ime-acceptance-"+nonce),marker=new File(root,"owned-v1");if(!root.exists()){if(!root.mkdirs())throw new IOException("Fixture directory");Files.write(marker.toPath(),nonce.getBytes(StandardCharsets.UTF_8));}if(!marker.isFile()||!new String(Files.readAllBytes(marker.toPath()),StandardCharsets.UTF_8).equals(nonce))throw new IOException("Unowned fixture");File files=new File(root,"files");files.mkdirs();return files;}catch(Exception invalid){throw new IllegalStateException("No owned synthetic input fixture",invalid);}}
 @Override public void onStartInput(EditorInfo info,boolean restarting){if(!"live.linghe.privateinput.tests".equals(info.packageName)){EditorInfo shield=new EditorInfo();shield.inputType=InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD;shield.imeOptions=EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING;super.onStartInput(shield,restarting);switchInputMethod("live.linghe.privateinput/.LingheInputService");return;}trace("startInput-before",restarting);super.onStartInput(info,restarting);trace("startInput-after",restarting);}
}
