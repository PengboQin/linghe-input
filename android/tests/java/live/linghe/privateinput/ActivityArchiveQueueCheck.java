package live.linghe.privateinput;

import android.content.*;
import android.database.DatabaseErrorHandler;
import android.database.sqlite.SQLiteDatabase;
import java.io.File;
import java.util.*;
import org.json.*;

/** Only a caller-chosen synthetic directory/test package; never uses the installed app. */
public final class ActivityArchiveQueueCheck {
  static int assertions;
  static void check(boolean value,String name){assertions++;if(!value)throw new AssertionError(name);}
  static final class IsolatedContext extends ContextWrapper {
    final File directory;
    IsolatedContext(File directory){super(null);this.directory=directory;directory.mkdirs();}
    @Override public Context getApplicationContext(){return this;}
    @Override public File getDatabasePath(String name){return new File(directory,name);}
    @Override public SQLiteDatabase openOrCreateDatabase(String name,int mode,SQLiteDatabase.CursorFactory factory){return SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name),factory);}
    @Override public SQLiteDatabase openOrCreateDatabase(String name,int mode,SQLiteDatabase.CursorFactory factory,DatabaseErrorHandler handler){return SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).getAbsolutePath(),factory,handler);}
  }
  static JSONObject event(String text)throws Exception{
    return new JSONObject().put("schema_version",1).put("event_id",ActivityArchiveRules.id())
      .put("device_group","00000000-0000-4000-8000-000000000001").put("device_id","00000000-0000-4000-8000-000000000002")
      .put("provider_id","ime.commit.v1").put("event_type","input_commit").put("observed_at","2026-10-18T12:00:00.000Z")
      .put("content",new JSONObject().put("text",text)).put("consent_version",1);
  }
  public static JSONObject run(File directory)throws Exception {
    IsolatedContext context=new IsolatedContext(directory);ActivityArchiveQueue queue=new ActivityArchiveQueue(context);
    check(queue.pending()==0,"new queue empty");JSONObject a=event("合成😀一"),b=event("合成😀一");
    check(queue.enqueue(a,7),"enqueue first");check(queue.enqueue(b,7),"same text independent event");
    check(a.getLong("device_seq")==1&&b.getLong("device_seq")==2,"durable seq monotonic");
    String installation=a.getString("installation_id");check(installation.equals(b.getString("installation_id")),"one installation");
    check(queue.batch(8).length()==0,"old generation not uploaded");queue.close();queue=new ActivityArchiveQueue(context);
    JSONArray rows=queue.batch(7);check(rows.length()==2&&queue.pending()==2,"restart keeps offline queue");
    check(rows.getJSONObject(0).getJSONObject("content").getString("text").equals("合成😀一"),"unicode unchanged");
    JSONObject partial=new JSONObject().put("accepted_event_ids",new JSONArray().put(a.getString("event_id"))).put("duplicate_event_ids",new JSONArray());
    boolean rejected=false;try{queue.acknowledge(rows,partial);}catch(Exception expected){rejected=true;}check(rejected&&queue.pending()==2,"incomplete receipt cannot delete");
    JSONObject foreign=new JSONObject().put("accepted_event_ids",new JSONArray().put(a.getString("event_id")).put(ActivityArchiveRules.id())).put("duplicate_event_ids",new JSONArray());
    rejected=false;try{queue.acknowledge(rows,foreign);}catch(Exception expected){rejected=true;}check(rejected&&queue.pending()==2,"foreign receipt cannot delete");
    JSONObject ack=new JSONObject().put("accepted_event_ids",new JSONArray().put(a.getString("event_id"))).put("duplicate_event_ids",new JSONArray().put(b.getString("event_id")));
    queue.acknowledge(rows,ack);check(queue.pending()==0,"only exact accepted or duplicate set removed");
    StringBuilder huge=new StringBuilder();for(int i=0;i<270000;i++)huge.append('x');check(!queue.enqueue(event(huge.toString()),7),"oversize rejected intact");
    JSONObject c=event("下一条");check(queue.enqueue(c,7)&&c.getLong("device_seq")==3,"failed insert consumes no seq");
    JSONObject collision=new JSONObject(c.toString());rejected=false;try{queue.enqueue(collision,7);}catch(Exception expected){rejected=true;}check(rejected&&queue.pending()==1,"ID collision rolls back");
    JSONObject d=event("再下一条");check(queue.enqueue(d,7)&&d.getLong("device_seq")==4,"collision consumes no seq");
    queue.clearPending();check(queue.pending()==0,"pause clears pending only");JSONObject e=event("暂停后");queue.enqueue(e,8);check(e.getLong("device_seq")==5,"pause keeps monotonic seq");
    queue.clearForDeparture();JSONObject f=event("新组");queue.enqueue(f,9);check(f.getLong("device_seq")==1&&!installation.equals(f.getString("installation_id")),"departure resets install namespace");queue.close();
    System.out.println("ActivityArchiveQueueCheck: SQLite checks passed; signing fixture next");JSONObject identity=SyncCrypto.identity();JSONObject wire=ActivityArchiveWire.envelope(identity,"00000000-0000-4000-8000-000000000001",1,new JSONObject(),1792324800L);
    check(wire.getInt("operation")==1&&!wire.getString("signature").isEmpty(),"archive namespace signed");
    return new JSONObject().put("assertions",assertions).put("wire",wire).put("public_key",identity.getString("signingPublic"));
  }
  public static void main(String[] args)throws Exception {
    if(args.length!=2||!args[0].startsWith("/data/local/tmp/linghe-activity-")||!args[1].startsWith("/data/local/tmp/linghe-activity-"))throw new IllegalArgumentException("isolated prefix required");
    System.out.println("ActivityArchiveQueueCheck: synthetic runner started");JSONObject result=run(new File(args[0]));try(java.io.FileOutputStream out=new java.io.FileOutputStream(args[1])){out.write(result.toString().getBytes(SyncCrypto.UTF8));}
    System.out.println("ActivityArchiveQueueCheck: "+result.getInt("assertions")+" assertions passed");
  }
}
