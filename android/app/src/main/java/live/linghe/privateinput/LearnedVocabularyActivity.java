package live.linghe.privateinput;
import android.app.Activity;import android.os.Bundle;import android.text.*;import android.view.*;import android.widget.*;
import java.io.File;import java.util.*;import java.util.concurrent.*;

/** Read-only saved learning list. No native engine, Rime database copy or network work. */
public final class LearnedVocabularyActivity extends Activity {
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private List<LearningModel.Entry> rows=Collections.emptyList();private String query="";private boolean loading;private String error;private long request;
 private String loadedGeneration;private boolean hasLoaded;
 private TextView status;private ListView list;private Button refresh;
 @Override public void onCreate(Bundle saved){Ui.prepareTheme(this);super.onCreate(saved);
  LinearLayout root=SettingsScreen.content(this,"已学习词汇",true,false);
  EditText search=new EditText(this);search.setSingleLine(true);search.setHint("搜索词语或拼音");search.setTextColor(Ui.text(this));search.setHintTextColor(Ui.muted(this));root.addView(search,new LinearLayout.LayoutParams(-1,-2));
  status=new TextView(this);status.setTextColor(Ui.muted(this));root.addView(status);
  list=new ListView(this);root.addView(list,new LinearLayout.LayoutParams(-1,0,1));
  TextView note=new TextView(this);note.setText("显示本机已保存的学习记录；刚学到的词在键盘保存后更新。");note.setTextColor(Ui.muted(this));note.setTextSize(13);root.addView(note);
  refresh=new Button(this);refresh.setText("刷新");refresh.setOnClickListener(v->load());root.addView(refresh);
  search.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int st,int c,int a){}public void onTextChanged(CharSequence s,int st,int before,int count){query=s.toString();render();}public void afterTextChanged(Editable e){}});
  load();
 }
 @Override protected void onStart(){super.onStart();
  String generation=PersonalReset.fileGeneration(getFilesDir());
  if(loadedGeneration!=null&&!loadedGeneration.equals(generation)){
   request++;rows=Collections.emptyList();error=null;loading=false;hasLoaded=false;loadedGeneration=generation;refresh.setEnabled(true);load();
  }else if(!hasLoaded&&!loading)load();
 }
 @Override protected void onStop(){request++;if(loading){loading=false;refresh.setEnabled(true);}hasLoaded=false;super.onStop();}
 private void load(){if(loading)return;final long token=++request;final String generation=PersonalReset.fileGeneration(getFilesDir());loading=true;error=null;rows=Collections.emptyList();refresh.setEnabled(false);render();
  worker.execute(()->{try{List<LearningModel.Entry> next=LearnedVocabularyProjection.read(getFilesDir(),new File(getFilesDir(),"Shared"));
    runOnUiThread(()->{if(token!=request||isFinishing()||isDestroyed())return;String current=PersonalReset.fileGeneration(getFilesDir());if(!generation.equals(current)){rows=Collections.emptyList();error="个人资料已重置，请重新打开。";loading=false;hasLoaded=false;refresh.setEnabled(true);render();return;}rows=next;loading=false;hasLoaded=true;loadedGeneration=generation;refresh.setEnabled(true);render();});
   }catch(Exception e){runOnUiThread(()->{if(token!=request||isFinishing()||isDestroyed())return;loading=false;hasLoaded=true;loadedGeneration=generation;refresh.setEnabled(true);error="暂时无法读取学习记录，请稍后刷新。原资料未修改。";rows=Collections.emptyList();render();});}});
 }
 private void render(){if(list==null)return;List<LearningModel.Entry> shown=LearnedVocabularyProjection.filter(rows,query);
  if(loading)status.setText("正在读取…");
  else if(error!=null)status.setText(error);
  else if(shown.isEmpty())status.setText(query.trim().isEmpty()?"暂无已保存的学习记录。":"没有匹配的词汇。");
  else status.setText(query.trim().isEmpty()?"已保存的学习记录 · "+rows.size()+" 条":"已保存的学习记录 · "+rows.size()+" 条（匹配 "+shown.size()+" 条）");
  if(shown.isEmpty()){list.setAdapter(null);return;}
  list.setAdapter(new BaseAdapter(){public int getCount(){return shown.size();}public Object getItem(int p){return shown.get(p);}public long getItemId(int p){return p;}
   public View getView(int p,View old,ViewGroup parent){TextView v=old instanceof TextView?(TextView)old:new TextView(LearnedVocabularyActivity.this);LearningModel.Entry e=shown.get(p);
    v.setText(e.text+"\n"+e.reading+" · "+e.frequency()+" 次"+(e.pinned?" · 置顶":""));v.setTextColor(Ui.text(LearnedVocabularyActivity.this));v.setTextSize(16);v.setSingleLine(false);v.setHorizontallyScrolling(false);v.setPadding(Ui.dp(LearnedVocabularyActivity.this,12),Ui.dp(LearnedVocabularyActivity.this,12),Ui.dp(LearnedVocabularyActivity.this,12),Ui.dp(LearnedVocabularyActivity.this,12));return v;}});
 }
 @Override public boolean onOptionsItemSelected(MenuItem item){if(item.getItemId()==android.R.id.home){finish();return true;}return super.onOptionsItemSelected(item);}
 @Override protected void onDestroy(){request++;worker.shutdownNow();super.onDestroy();}
}
