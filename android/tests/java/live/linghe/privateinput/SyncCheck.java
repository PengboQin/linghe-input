package live.linghe.privateinput;
import android.app.*;
import android.os.*;
import android.content.*;
import java.io.*;
import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;
import org.json.*;
/** Only this test application's fresh UUID directory and synthetic device group. */
public final class SyncCheck extends Instrumentation {
  private Bundle arguments;
  private int checks;
  private void require(boolean b,String label){
    if(!b)throw new AssertionError(label);
    checks++;
  }
  @Override public void onCreate(Bundle b){
    super.onCreate(b);
    arguments=b;
    start();
  }
  @Override public void onStart(){
    Bundle result=new Bundle();
    try{
      Context base=getTargetContext();
      String nonce=UUID.randomUUID().toString();
      File root=new File(base.getCacheDir(),"sync-fixture-"+nonce);
      root.mkdirs();
      Context fixture=new ContextWrapper(base){
        @Override public Context getApplicationContext(){
          return this;
        }
        @Override public File getFilesDir(){
          return root;
        }
        @Override public android.content.SharedPreferences getSharedPreferences(String name,int mode){
          return base.getSharedPreferences("sync-fixture-"+nonce+"-"+name,mode);
        }
      }
      ;
      SyncClient client=new SyncClient(fixture);
      require(!client.connected(),"fresh group");
      client.join(arguments.getString("code"),arguments.getString("endpoint"));
      long deadline=System.currentTimeMillis()+70000;
      while(!client.connected()&&System.currentTimeMillis()<deadline){
        try{
          client.synchronize();
        }
        catch(SyncClient.HTTPFailure waiting){
          if(waiting.status!=403&&waiting.status!=404)throw waiting;
        }
        Thread.sleep(500);
      }
      require(client.connected()&&client.members()==2,"real short-code pairing");
      SyncClient restarted=new SyncClient(fixture);
      require(restarted.connected(),"keystore encrypted restart");
      String wire=AppFiles.read(new File(root,"Sync/state-v1.enc"),8*1024*1024);
      require(!wire.contains("signingPublic")&&!wire.contains("groupKey")&&!wire.contains("BEGIN"),"identity and group key encrypted on disk");
      client=restarted;
      client.consent(true,true);
      PersonalLexicon personal=new PersonalLexicon(new File(root,"Shared"));
      boolean received=false;
      deadline=System.currentTimeMillis()+45000;
      while(!received&&System.currentTimeMillis()<deadline){
        client.synchronize();
        boolean word=false,phrase=false;
        for(PersonalLexicon.Entry e:personal.load().entries){
          word|=e.text.equals("合成互通");
          phrase|=e.text.equals("跨端快捷短语验证");
        }
        boolean text=false;
        JSONArray inbox=client.inbox();
        for(int i=0;i<inbox.length();i++)text|=inbox.getJSONObject(i).getString("text").equals("Mac到安卓真实同步验证");
        received=word&&phrase&&text;
        if(!received)Thread.sleep(500);
      }
      require(received,"Apple word, phrase, shared text arrived");
      String archive=new LearningSnapshotFile(new File(root,"Shared")).read();
      LearningModel imported=new LearningModel();
      imported.merge(archive);
      require(imported.entries().stream().anyMatch(e->e.text.equals("灵鹤")&&e.frequency()>=23),"Apple frequency counters arrived");
      PersonalLexicon.Entry back=PersonalLexicon.Entry.create("phrase","安卓合成回传","azht");
      personal.upsert(back,null);
      personal.remove("55555555-5555-4555-8555-555555555551");
      client.sendText("安卓到Mac真实同步验证");
      client.synchronize();
      require(!personal.load().entries.stream().anyMatch(e->e.text.equals("合成互通")),"local delete materialized");
      Thread.sleep(1500);
      client.synchronize();
      require(!personal.load().entries.stream().anyMatch(e->e.text.equals("合成互通")),"old remote snapshot does not resurrect deletion");
      Field stateField=SyncClient.class.getDeclaredField("state");
      stateField.setAccessible(true);
      JSONObject state=(JSONObject)stateField.get(client);
      String device=state.getJSONObject("identity").getString("device");
      BigIntegerHelper.sequence(state);
      require(new SyncClient(fixture).connected(),"sequence and received state durable");
      client.consent(false,false);
      require(!client.learning()&&!client.clipboard(),"separate consent can be paused");
      SyncClient paused=client;
      try{
        paused.sendText("不应发送");
        throw new AssertionError("disabled clipboard sent");
      }
      catch(IOException expected){
        checks++;
      }
      for(String invalid:new String[]{
        "http://example.com","https://user:password@example.com","https://example.com/?token=x","https://example.com/#fragment"
      }
      ){
        try{
          SyncClient.endpoint(invalid);
          throw new AssertionError("unsafe endpoint accepted");
        }
        catch(Exception expected){
          checks++;
        }
      }
      result.putString("result","Passed");
      result.putInt("checks",checks);
      result.putString("fixture",nonce);
      finish(0,result);
    }
    catch(Throwable failure){
      result.putString("result","Failed");
      result.putString("failure",failure.getClass().getSimpleName()+": "+failure.getMessage());
      finish(1,result);
    }
  }
  private static class BigIntegerHelper {
    static void sequence(JSONObject state)throws Exception{
      if(SyncCrypto.u(state,"sequence").signum()<=0)throw new AssertionError("sequence reserved before sending");
    }
  }
}
