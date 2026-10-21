package live.linghe.privateinput;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import java.io.*;
import java.net.*;
import java.text.SimpleDateFormat;
import java.util.*;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;

/** Real TLS, product wire signing and SQLite, exclusively in this test App.
 * Fixture intake uses only this App's normal scoped external-files directory.
 * No ClipboardManager, InputConnection, product data, global permissions or IME switch.
 */
public final class ActivityArchiveHttpInstrumentation extends Instrumentation {
  private Bundle arguments;private int assertions;private String stage="initial";
  private JSONObject fixture,identity;private String endpoint,group,device;private ActivityArchiveQueue queue;
  private File localDirectory,intake;private JSONArray eventIDs=new JSONArray();private boolean erased,closed;
  private void check(boolean value,String label){assertions++;if(!value)throw new AssertionError(label);}
  private static boolean remove(File file){if(!file.exists())return true;boolean success=true;File[] children=file.listFiles();if(children!=null)for(File child:children)success=remove(child)&&success;return file.delete()&&success;}
  @Override public void onCreate(Bundle arguments){super.onCreate(arguments);this.arguments=arguments;start();}
  @Override public void onStart(){
    Bundle result=new Bundle();JSONObject report=new JSONObject();boolean success=false,clean=true;
    try{
      Context context=getTargetContext();check(context.getPackageName().equals("live.linghe.privateinput.tests"),"isolated test package only");
      File external=context.getExternalFilesDir(null);check(external!=null,"own scoped external directory available");
      File directory=new File(external,"archive-http");if(!directory.exists()&&!directory.mkdirs())throw new IOException("fixture intake directory");intake=new File(directory,"fixture.json");
      if("prepare".equals(arguments.getString("stage","run"))){
        check(!intake.exists()||intake.delete(),"old disposable fixture cleared");
        result.putString("intake",intake.getAbsolutePath());result.putString("stage","prepared");finish(-1,result);return;
      }
      stage="fixture";check(intake.isFile()&&intake.length()<=65536,"bounded private fixture present");
      byte[] raw;try(InputStream in=new FileInputStream(intake)){ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buffer=new byte[4096];int count;while((count=in.read(buffer))!=-1){if(bytes.size()+count>65536)throw new IOException("fixture too large");bytes.write(buffer,0,count);}raw=bytes.toByteArray();}
      try{fixture=LosslessJson.object(SyncCrypto.utf8(raw),65536);}finally{Arrays.fill(raw,(byte)0);check(intake.delete(),"fixture deleted immediately after intake");}
      endpoint=SyncClient.endpoint(fixture.getString("endpoint"));group=ActivityArchiveRules.id(fixture.getString("group"));device=ActivityArchiveRules.id(fixture.getString("device"));
      check(group.equals(ActivityArchiveRules.id(fixture.getJSONObject("membership").getString("group"))),"fixture group internally bound");
      JSONObject own=SyncCrypto.find(fixture.getJSONObject("membership"),device);
      check(own.getInt("permissions")==3&&own.getString("signingPublic").equals(fixture.getString("signing_public_base64")),"synthetic full member matches key");
      identity=new JSONObject().put("device",device).put("signing",fixture.getString("signing_private_pkcs8_base64")).put("signingPublic",fixture.getString("signing_public_base64"));
      localDirectory=new File(context.getFilesDir(),"archive-https-"+ActivityArchiveRules.id());
      queue=new ActivityArchiveQueue(new ActivityArchiveQueueCheck.IsolatedContext(localDirectory));
      stage="status";JSONObject status=rpc(1,new JSONObject());check(!status.getBoolean("enabled"),"fresh synthetic group default off");
      stage="policy";rpc(2,new JSONObject().put("expected_version",status.getLong("policy_version")).put("enabled",true).put("retention_days",1).put("max_group_bytes",1048576));
      stage="consent";JSONObject now=rpc(1,new JSONObject());JSONObject old=now.optJSONObject("consent");
      JSONObject consent=rpc(3,new JSONObject().put("expected_version",old==null?0:old.getLong("version")).put("enabled",true)
        .put("providers",new JSONArray().put("ime.commit.v1").put("clipboard.observed.v1").put("app.paste.v1")).put("readers",new JSONArray().put(device)));
      long version=consent.getLong("consent_version");check(version>0,"explicit own consent active");
      String[] texts={"合成输入：明天下午讨论方案😀","合成剪贴板：café · mañana\n中文与 emoji🪶","合成明确粘贴：1.4 @ exemple.fr"};
      String[] providers={"ime.commit.v1","clipboard.observed.v1","app.paste.v1"},types={"input_commit","clipboard_observed","paste_action"},sources={"ime","clipboard","app_paste"};
      String inputSession=ActivityArchiveRules.id();
      stage="queue";for(int index=0;index<texts.length;index++){
        JSONObject event=event(providers[index],types[index],sources[index],texts[index],version,inputSession);
        check(queue.enqueue(event,101),"synthetic event durable");eventIDs.put(event.getString("event_id"));
      }
      check(queue.pending()==3,"three durable records offline");JSONArray events=queue.batch(101);
      ArrayList<String> ids=new ArrayList<>();for(int index=0;index<events.length();index++)ids.add(events.getJSONObject(index).getString("event_id"));String batchID=ActivityArchiveRules.batchID(ids);
      JSONObject body=new JSONObject().put("batch_id",batchID).put("events",events);
      stage="ingest_ignore_local_ack";JSONObject ignored=rpc(4,body);check(ignored.getJSONArray("accepted_event_ids").length()==3,"server persisted three records");
      // Deliberately ignore the real successful response, then reopen the queue.
      // This simulates lost local ACK after persistence, not a fabricated TLS result.
      queue.close();queue=new ActivityArchiveQueue(new ActivityArchiveQueueCheck.IsolatedContext(localDirectory));
      check(queue.pending()==3,"ignored ACK does not remove records after restart");
      JSONArray retried=queue.batch(101);ArrayList<String> retryIDs=new ArrayList<>();for(int index=0;index<retried.length();index++)retryIDs.add(retried.getJSONObject(index).getString("event_id"));
      check(batchID.equals(ActivityArchiveRules.batchID(retryIDs)),"retry stable batch identity");
      stage="retry";JSONObject receipt=rpc(4,new JSONObject().put("batch_id",batchID).put("events",retried));
      check(batchID.equals(ActivityArchiveRules.id(receipt.getString("batch_id"))),"actual receipt bound to stable batch");
      queue.acknowledge(retried,receipt);check(queue.pending()==0,"only actual complete receipt removes queue");
      stage="query";JSONArray stored=rpc(5,new JSONObject().put("limit",50)).getJSONArray("events");check(stored.length()==3,"retry produced no duplicate records");
      Map<String,JSONObject> byID=new HashMap<>();for(int index=0;index<stored.length();index++){JSONObject row=stored.getJSONObject(index);byID.put(row.getString("event_id"),row);}
      for(int index=0;index<texts.length;index++){
        JSONObject row=byID.get(eventIDs.getString(index));check(row!=null&&row.getJSONObject("content").getString("text").equals(texts[index]),"Unicode plaintext exactly preserved");
        check(row.getString("event_type").equals(types[index])&&row.getString("provider_id").equals(providers[index]),"three source types remain distinct");
      }
      stage="erase";JSONObject deletion=rpc(9,new JSONObject().put("event_ids",eventIDs));check(deletion.getJSONArray("erased_event_ids").length()==3,"all synthetic plaintext erased");
      check(rpc(5,new JSONObject().put("limit",50)).getJSONArray("events").length()==0,"query empty after erasure");erased=true;
      stage="close";JSONObject beforeClose=rpc(1,new JSONObject());rpc(2,new JSONObject().put("expected_version",beforeClose.getLong("policy_version")).put("enabled",false).put("retention_days",1).put("max_group_bytes",1048576));
      check(!rpc(1,new JSONObject()).getBoolean("enabled"),"synthetic group closed");closed=true;
      report.put("actual_https",true).put("product_wire_signature",true).put("actual_android_sqlite",true).put("unicode_sources",3)
        .put("lost_local_ack_simulated_after_real_persistence",true).put("restart_retry_no_duplicates",true).put("exact_actual_ack",true).put("full_plaintext_query_matched",true);
      success=true;
    }catch(Throwable failure){try{report.put("error",failure instanceof HTTPFailure?((HTTPFailure)failure).code:failure.getClass().getSimpleName()).put("failed_stage",stage);}catch(Exception ignored){}}
    finally{
      if(queue!=null)try{queue.close();}catch(Exception ignored){}
      if(identity!=null&&!closed){try{
        stage="cleanup";JSONArray rows=rpc(5,new JSONObject().put("limit",128)).getJSONArray("events");JSONArray ids=new JSONArray();for(int i=0;i<rows.length();i++)ids.put(rows.getJSONObject(i).getString("event_id"));if(ids.length()>0)rpc(9,new JSONObject().put("event_ids",ids));erased=rpc(5,new JSONObject().put("limit",1)).getJSONArray("events").length()==0;
        JSONObject state=rpc(1,new JSONObject());if(state.getBoolean("enabled"))rpc(2,new JSONObject().put("expected_version",state.getLong("policy_version")).put("enabled",false).put("retention_days",1).put("max_group_bytes",1048576));closed=!rpc(1,new JSONObject()).getBoolean("enabled");
      }catch(Exception cleanupFailure){clean=false;}}
      if(localDirectory!=null)clean=remove(localDirectory)&&clean;if(intake!=null&&intake.exists())clean=intake.delete()&&clean;
      fixture=null;identity=null;
    }
    try{report.put("assertions",assertions).put("synthetic_plaintext_erased",erased).put("synthetic_group_closed",closed).put("local_fixture_and_queue_removed",clean)
      .put("real_clipboard_read",false).put("main_app_launched",false).put("production_archive_enabled",false);}catch(Exception ignored){}
    result.putString("result",report.toString());finish(success&&clean&&erased&&closed?-1:1,result);
  }
  private JSONObject event(String provider,String type,String source,String text,long version,String session)throws Exception{
    long now=System.currentTimeMillis();SimpleDateFormat formatter=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",Locale.ROOT);formatter.setTimeZone(TimeZone.getTimeZone("UTC"));
    return new JSONObject().put("schema_version",1).put("event_id",ActivityArchiveRules.id()).put("device_group",group).put("device_id",device)
      .put("provider_id",provider).put("event_type",type).put("observed_at",formatter.format(new Date(now))).put("timezone_id",TimeZone.getDefault().getID()).put("utc_offset_minutes",TimeZone.getDefault().getOffset(now)/60000)
      .put("content",new JSONObject().put("text",text)).put("consent_version",version).put("source_kind",source).put("source_app",JSONObject.NULL)
      .put("input_session",type.equals("input_commit")?session:JSONObject.NULL).put("editor_epoch",type.equals("input_commit")?session:JSONObject.NULL)
      .put("edit_op",new JSONObject().put("kind","unknown").put("anchor",JSONObject.NULL)).put("delivery_state","draft_unknown").put("commit_confirmation",type.equals("clipboard_observed")?"observed_match":"editor_acknowledged")
      .put("extensions",new JSONObject().put("org.linghe.testing.v1",new JSONObject().put("synthetic",true)));
  }
  private static final class HTTPFailure extends IOException {final String code;HTTPFailure(String code){this.code=code;}}
  private JSONObject rpc(int operation,JSONObject body)throws Exception{
    HttpsURLConnection connection=(HttpsURLConnection)new URL(endpoint+"/v1/activity/rpc").openConnection();
    connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(10000);connection.setReadTimeout(15000);connection.setUseCaches(false);connection.setRequestMethod("POST");connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("Accept","application/json");
    byte[] payload=SyncCrypto.bytes(ActivityArchiveWire.envelope(identity,group,operation,body,System.currentTimeMillis()/1000).toString());connection.setDoOutput(true);connection.setFixedLengthStreamingMode(payload.length);
    try{
      try(OutputStream out=connection.getOutputStream()){out.write(payload);}
      int code=connection.getResponseCode();ByteArrayOutputStream bytes=new ByteArrayOutputStream();InputStream stream=code==200?connection.getInputStream():connection.getErrorStream();
      if(stream!=null)try(InputStream in=stream){byte[] buffer=new byte[8192];int count;while((count=in.read(buffer))!=-1){if(bytes.size()+count>1048576)throw new IOException("bounded response");bytes.write(buffer,0,count);}}
      JSONObject response=LosslessJson.object(SyncCrypto.utf8(bytes.toByteArray()),1048576);
      if(code!=200){String reason=response.optString("error","http_failure");throw new HTTPFailure(reason.matches("[a-z_]{1,64}")?reason:"http_failure");}
      check(response.getInt("version")==1&&response.getInt("operation")==operation,"RPC version and operation matched");return response.getJSONObject("result");
    }finally{connection.disconnect();}
  }
}
