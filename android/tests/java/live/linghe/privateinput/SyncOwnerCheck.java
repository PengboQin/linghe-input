package live.linghe.privateinput;
import android.app.*;
import android.os.*;
import android.content.*;
import java.io.*;
import org.json.*;
import java.util.*;
public final class SyncOwnerCheck extends Instrumentation {
  private Bundle arguments;
  private volatile String phase="initial";
  private volatile boolean observing;
  @Override public void onCreate(Bundle b){
    super.onCreate(b);
    arguments=b;
    start();
  }
  private void require(boolean value,String text){
    if(!value)throw new AssertionError(text);
  }
  @Override public void onStart(){
    Bundle result=new Bundle();
    try{
      Context base=getTargetContext();
      observing=true;
      Thread targetThread=Thread.currentThread();
      Thread watchdog=new Thread(()->{
        while(observing){
          try{
            Thread.sleep(5000);StringBuilder trace=new StringBuilder("phase="+phase+"\n");for(StackTraceElement frame:targetThread.getStackTrace())trace.append(frame.toString()).append('\n');try(FileOutputStream out=new FileOutputStream(new File(base.getExternalFilesDir(null),"sync-owner-stack.txt"))){
              out.write(trace.toString().getBytes(SyncCrypto.UTF8));
            }
          }
          catch(Exception ignored){
          }
        }
      }
      ,"own-sync-fixture-watchdog");
      watchdog.setDaemon(true);
      watchdog.start();
      String nonce=UUID.randomUUID().toString();
      File root=new File(base.getCacheDir(),"sync-owner-"+nonce);
      root.mkdirs();
      Context fixture=new ContextWrapper(base){
        public Context getApplicationContext(){
          return this;
        }
        public File getFilesDir(){
          return root;
        }
        public android.content.SharedPreferences getSharedPreferences(String name,int mode){
          return base.getSharedPreferences("sync-owner-"+nonce+"-"+name,mode);
        }
      }
      ;
      SyncClient client=new SyncClient(fixture);
      phase="register";
      client.createGroup(arguments.getString("endpoint"));
      phase="ticket";
      client.consent(false,false);
      JSONObject previous=client.invite();
      JSONObject ticket=client.invite();
      ticket.put("previousLink",previous.getString("link"));
      com.google.zxing.common.BitMatrix qr=new com.google.zxing.qrcode.QRCodeWriter().encode(ticket.getString("link"),com.google.zxing.BarcodeFormat.QR_CODE,640,640);
      byte[] image=new byte[640*640];
      for(int y=0;y<640;y++)for(int x=0;x<640;x++)image[y*640+x]=(byte)(qr.get(x,y)?0:255);
      com.google.zxing.Result decoded=new com.google.zxing.qrcode.QRCodeReader().decode(new com.google.zxing.BinaryBitmap(new com.google.zxing.common.HybridBinarizer(new com.google.zxing.PlanarYUVLuminanceSource(image,640,640,0,0,640,640,false))));
      require(decoded.getText().equals(ticket.getString("link")),"offline scanner codec round trip");
      phase="ownerGrant";
      try(FileOutputStream out=new FileOutputStream(new File(base.getExternalFilesDir(null),"sync-owner-ticket.json"))){
        out.write(ticket.toString().getBytes(SyncCrypto.UTF8));
      }
      long deadline=System.currentTimeMillis()+120000;
      while(client.members()<2&&System.currentTimeMillis()<deadline){
        client.synchronize();
        Thread.sleep(500);
      }
      require(client.members()==2,"Android owner quick-QR admission");
      require(!client.learning()&&!client.clipboard(),"invitation does not enable content sharing");
      client.consent(true,true);
      phase="content";
      PersonalLexicon personal=new PersonalLexicon(new File(root,"Shared"));
      personal.upsert(PersonalLexicon.Entry.create("phrase","安卓主设备短语","mpaz"),null);
      client.sendText("安卓主设备同步验证");
      boolean received=false;
      while(!received&&System.currentTimeMillis()<deadline){
        client.synchronize();
        boolean phrase=personal.load().entries.stream().anyMatch(e->e.text.equals("Mac新设备短语")),text=false;
        JSONArray inbox=client.inbox();
        for(int i=0;i<inbox.length();i++)text|=inbox.getJSONObject(i).getString("text").equals("Mac新设备同步验证");
        boolean confirmed=false;
        for(int i=0;i<inbox.length();i++)confirmed|=inbox.getJSONObject(i).getString("text").equals("Mac确认已收到");
        received=phrase&&text&&confirmed;
        if(!received)Thread.sleep(500);
      }
      require(received,"Apple to Android owner texts and phrase");
      phase="revoke";
      String peer=null;
      JSONArray devices=client.devices();
      for(int n=0;n<devices.length();n++)if(!devices.getJSONObject(n).getBoolean("thisDevice"))peer=devices.getJSONObject(n).getString("device");
      require(peer!=null,"member listed");
      client.revoke(peer);
      client.synchronize();
      require(client.members()==1,"revoked pair cannot be automatically reapproved");
      require(personal.load().entries.stream().anyMatch(e->e.text.equals("Mac新设备短语")),"removing device preserves dictionary history");
      SyncClient restarted=new SyncClient(fixture);
      require(restarted.connected()&&restarted.members()==1,"Android root persisted after grant");
      observing=false;
      result.putString("result","Passed");
      result.putString("rootOwner","Android");
      result.putString("protocol","existing Apple quick QR / root-signed membership / rotated content key / bidirectional encrypted content");
      finish(0,result);
    }
    catch(Throwable error){
      observing=false;
      result.putString("result","Failed");
      result.putString("phase",phase);
      result.putString("failure",error.getClass().getSimpleName()+": "+error.getMessage()+(error instanceof SyncClient.HTTPFailure?" / "+((SyncClient.HTTPFailure)error).serverCode:""));
      finish(1,result);
    }
  }
}
