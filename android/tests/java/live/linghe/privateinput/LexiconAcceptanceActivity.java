package live.linghe.privateinput;
import android.os.*;import android.content.*;import android.provider.DocumentsContract;import java.io.*;import java.nio.charset.StandardCharsets;import java.util.*;import org.json.*;

/** The actual settings controller with only a fresh, explicitly synthetic data root. */
public final class LexiconAcceptanceActivity extends PersonalLexiconActivity {
 static final String AUTHORITY="live.linghe.privateinput.tests.documents";private String fixture;
 private String fixture(){if(fixture==null){String value=getIntent().getStringExtra("fixture");fixture=UUID.fromString(value).toString();}return fixture;}
 private File root(){return new File(super.getCacheDir(),"lexicon-acceptance-"+fixture());}
 @Override public File getFilesDir(){File file=new File(root(),"files");file.mkdirs();return file;}
 @Override public void onCreate(Bundle saved){
  if(saved!=null)fixture=saved.getString("fixture");
  try{File root=root();boolean fresh=!root.exists();root.mkdirs();File marker=new File(root,"fixture-owned-v1");if(fresh){try(OutputStream output=new FileOutputStream(marker)){output.write(fixture().getBytes(StandardCharsets.UTF_8));}PersonalLexicon store=new PersonalLexicon(new File(getFilesDir(),"Shared"));store.upsert(new PersonalLexicon.Entry("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","phrase","本地保留合成","bl"),null);File docs=new File(root,"documents");docs.mkdirs();JSONArray entries=new JSONArray().put(new PersonalLexicon.Entry("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","phrase","远端冲突合成","bl").json()).put(new PersonalLexicon.Entry("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","phrase","导入合成短语","dr").json()).put(new PersonalLexicon.Entry("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","word","合成词条","he cheng ci tiao").json());try(OutputStream output=new FileOutputStream(new File(docs,"import.json"))){output.write(new JSONObject().put("version",1).put("entries",entries).toString().getBytes(StandardCharsets.UTF_8));}}
   if(!marker.isFile())throw new IOException("Unowned fixture");getSharedPreferences("document-harness",0).edit().putString("fixture",fixture()).commit();
  }catch(Exception failure){finish();return;}
  super.onCreate(saved);
 }
 @Override protected void launchDocumentPicker(Intent intent,int request){intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI,DocumentsContract.buildDocumentUri(AUTHORITY,fixture()+"|root"));super.launchDocumentPicker(intent,request);}
 @Override protected void onSaveInstanceState(Bundle out){out.putString("fixture",fixture());super.onSaveInstanceState(out);}
}
