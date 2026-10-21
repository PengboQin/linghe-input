package live.linghe.privateinput;
import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import java.io.File;
import java.security.SecureRandom;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Persistent device-local receipts, never clipboard text. Runs only on IO workers.
 * No eviction: a storage failure skips automatic delivery instead of replaying it.
 * The privacy departure barrier removes the complete ClipboardOnce directory. */
final class ClipboardOnceReceipts {
 static final int DELIVERY=1,CANDIDATE=2;
 static byte[] fingerprint(byte[] salt,String text)throws Exception{Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(salt,"HmacSHA256"));return mac.doFinal(text.getBytes(java.nio.charset.StandardCharsets.UTF_8));}
 static boolean claim(Context context,int kind,String text,String privacy)throws Exception{
  if(kind!=DELIVERY&&kind!=CANDIDATE)throw new IllegalArgumentException("receipt kind");
  File directory=new File(context.getFilesDir(),"ClipboardOnce");
  return AppFiles.locked(directory,"once.lock",()->{
   if(!privacy.equals(PersonalReset.generation(context))||context.getSharedPreferences("privacy-reset",0).getBoolean("pending",false))return false;
   try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(new File(directory,"receipts-v1.sqlite"),null)){
    db.setMaximumSize(16L*1024*1024);db.execSQL("PRAGMA synchronous=FULL");
    db.execSQL("CREATE TABLE IF NOT EXISTS metadata(id INTEGER PRIMARY KEY,salt BLOB NOT NULL)");
    db.execSQL("CREATE TABLE IF NOT EXISTS seen(kind INTEGER NOT NULL,fingerprint BLOB NOT NULL,PRIMARY KEY(kind,fingerprint)) WITHOUT ROWID");
    db.beginTransaction();try{
     byte[] salt;try(Cursor c=db.rawQuery("SELECT salt FROM metadata WHERE id=1",null)){if(c.moveToFirst())salt=c.getBlob(0);else{salt=new byte[32];new SecureRandom().nextBytes(salt);ContentValues v=new ContentValues();v.put("id",1);v.put("salt",salt);db.insertOrThrow("metadata",null,v);}}
     ContentValues row=new ContentValues();row.put("kind",kind);row.put("fingerprint",fingerprint(salt,text));
     boolean fresh=db.insertWithOnConflict("seen",null,row,SQLiteDatabase.CONFLICT_IGNORE)!=-1;
     if(!privacy.equals(PersonalReset.generation(context))||context.getSharedPreferences("privacy-reset",0).getBoolean("pending",false))return false;
     db.setTransactionSuccessful();return fresh;
    }finally{db.endTransaction();}
   }
  });
 }
 private ClipboardOnceReceipts(){}
}
