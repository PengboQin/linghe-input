package live.linghe.privateinput;
import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import java.util.*;
import org.json.*;

/** App-private transactional queue; seq allocation and event insertion commit together. */
final class ActivityArchiveQueue extends SQLiteOpenHelper {
  static final long MAX_BYTES=16L*1024*1024;
  static final int MAX_EVENTS=10000;
  ActivityArchiveQueue(Context context){super(context,"activity-archive-v1.sqlite",null,1);}
  @Override public void onConfigure(SQLiteDatabase db){
    db.setForeignKeyConstraintsEnabled(true);
    try(Cursor result=db.rawQuery("PRAGMA secure_delete=ON",null)){if(!result.moveToFirst()||result.getInt(0)!=1)throw new IllegalStateException("Archive secure delete unavailable");}
    db.setMaximumSize(32L*1024*1024);
  }
  @Override public void onCreate(SQLiteDatabase db){
    db.execSQL("CREATE TABLE meta(k TEXT PRIMARY KEY,v TEXT NOT NULL)");
    db.execSQL("INSERT INTO meta VALUES('installation', '"+ActivityArchiveRules.id()+"')");
    db.execSQL("INSERT INTO meta VALUES('seq','0')");
    db.execSQL("CREATE TABLE queue(event_id TEXT PRIMARY KEY,seq INTEGER NOT NULL UNIQUE,generation INTEGER NOT NULL,payload TEXT NOT NULL,bytes INTEGER NOT NULL)");
  }
  @Override public void onUpgrade(SQLiteDatabase db,int old,int next){throw new IllegalStateException("Archive migration required");}
  private String meta(SQLiteDatabase db,String key){try(Cursor c=db.rawQuery("SELECT v FROM meta WHERE k=?",new String[]{key})){if(!c.moveToFirst())throw new IllegalStateException("Archive metadata missing");return c.getString(0);}}
  synchronized boolean enqueue(JSONObject event,long generation)throws Exception {
    SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
    try {
      long previous=Long.parseLong(meta(db,"seq"));if(previous<0||previous==Long.MAX_VALUE)throw new IllegalStateException("Archive sequence exhausted");long sequence=previous+1;
      event.put("installation_id",meta(db,"installation")).put("device_seq",sequence);
      String payload=LosslessJson.canonical(event);int bytes=ActivityArchiveRules.bytes(payload).length;
      long size=0,count=0;try(Cursor c=db.rawQuery("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM queue",null)){c.moveToFirst();count=c.getLong(0);size=c.getLong(1);}
      if(bytes>262144||count>=MAX_EVENTS||size+bytes>MAX_BYTES)return false;
      if("ime.diagnostic.v1".equals(event.optString("provider_id"))&&(count>=MAX_EVENTS*3/4||size+bytes>MAX_BYTES*3/4))return false;
      ContentValues values=new ContentValues();values.put("event_id",event.getString("event_id"));values.put("seq",sequence);values.put("generation",generation);values.put("payload",payload);values.put("bytes",bytes);
      db.insertOrThrow("queue",null,values);ContentValues seq=new ContentValues();seq.put("v",Long.toString(sequence));db.update("meta",seq,"k='seq'",null);
      db.setTransactionSuccessful();return true;
    }finally{db.endTransaction();}
  }
  synchronized JSONArray batch(long generation)throws Exception {
    JSONArray result=new JSONArray();int bytes=128;
    try(Cursor c=getReadableDatabase().rawQuery("SELECT payload,bytes FROM queue WHERE generation=? ORDER BY seq LIMIT 128",new String[]{Long.toString(generation)})){
      while(c.moveToNext()){if(bytes+c.getInt(1)+1>480*1024)break;bytes+=c.getInt(1)+1;result.put(LosslessJson.object(c.getString(0),262144));}
    }return result;
  }
  synchronized void acknowledge(JSONArray batch,JSONObject response)throws Exception {
    Set<String> sent=new HashSet<>();for(int i=0;i<batch.length();i++)sent.add(batch.getJSONObject(i).getString("event_id"));
    Set<String> accepted=new HashSet<>();for(String key:new String[]{"accepted_event_ids","duplicate_event_ids"}){
      JSONArray rows=response.getJSONArray(key);for(int i=0;i<rows.length();i++){String id=ActivityArchiveRules.id(rows.getString(i));if(!sent.contains(id))throw new IllegalStateException("Archive receipt mismatch");accepted.add(id);}
    }
    if(!accepted.equals(sent))throw new IllegalStateException("Archive receipt incomplete");
    SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{for(String id:accepted)db.delete("queue","event_id=?",new String[]{id});db.setTransactionSuccessful();}finally{db.endTransaction();}
  }
  synchronized long pending(long generation){try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM queue WHERE generation=?",new String[]{Long.toString(generation)})){c.moveToFirst();return c.getLong(0);}}
  synchronized long pending(){try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM queue",null)){c.moveToFirst();return c.getLong(0);}}
  synchronized void clearPending(){getWritableDatabase().delete("queue",null,null);}
  synchronized void clearForDeparture(){SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{db.delete("queue",null,null);ContentValues value=new ContentValues();value.put("v",ActivityArchiveRules.id());db.update("meta",value,"k='installation'",null);value.put("v","0");db.update("meta",value,"k='seq'",null);db.setTransactionSuccessful();}finally{db.endTransaction();}}
}
