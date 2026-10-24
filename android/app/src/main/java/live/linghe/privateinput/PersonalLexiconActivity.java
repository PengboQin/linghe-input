package live.linghe.privateinput;

import android.app.*;import android.os.*;import android.content.*;import android.graphics.Color;import android.text.*;import android.view.*;import android.view.inputmethod.EditorInfo;import android.widget.*;
import java.io.*;import java.util.*;import java.util.concurrent.*;

public class PersonalLexiconActivity extends Activity {
 private PersonalLexicon store;private PersonalLexicon.Snapshot state;private boolean removed=false,busy=false;private String query="";private Button add,more;private SearchView search;
 private final ExecutorService worker=Executors.newSingleThreadExecutor();private LinearLayout root;private ListView list;private TextView empty;private Set<String> syllables;private Object removedBack;
 private boolean receiverRegistered=false;private final BroadcastReceiver changes=new BroadcastReceiver(){@Override public void onReceive(Context context,Intent intent){if(PersonalChangeSignal.ACTION.equals(intent.getAction()))load();}};
 private int dp(int n){return Ui.dp(this,n);}
 @Override public void onCreate(Bundle saved){Ui.prepareTheme(this);super.onCreate(saved);store=new PersonalLexicon(new File(getFilesDir(),"Shared"));if(saved!=null){removed=saved.getBoolean("removed",false);query=saved.getString("query","");}root=SettingsScreen.content(this,"个人词库与短语",true,false);root.setPadding(dp(20),dp(8),dp(20),dp(16));
  LinearLayout actions=new LinearLayout(this);actions.setGravity(Gravity.CENTER_VERTICAL);add=button("新增",()->edit(null));actions.addView(add,new LinearLayout.LayoutParams(dp(52),dp(48)));more=button("⋯",this::moreMenu);more.setContentDescription("更多词库操作");actions.addView(more,new LinearLayout.LayoutParams(dp(40),dp(48)));if(getActionBar()!=null){getActionBar().setDisplayShowCustomEnabled(true);getActionBar().setCustomView(actions,new ActionBar.LayoutParams(-2,-1,Gravity.END|Gravity.CENTER_VERTICAL));}
  search=new SearchView(this);search.setId(4101);search.setIconifiedByDefault(false);search.setQueryHint("搜索词条、拼音或缩写");search.setImeOptions(EditorInfo.IME_ACTION_SEARCH|EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);search.setMaxWidth(Integer.MAX_VALUE);search.setOnQueryTextListener(new SearchView.OnQueryTextListener(){public boolean onQueryTextSubmit(String value){search.clearFocus();return true;}public boolean onQueryTextChange(String value){query=value;refresh();return true;}});root.addView(search,new LinearLayout.LayoutParams(-1,dp(52)));
  search.setQuery(query,false);empty=text("",15,Ui.muted(this));empty.setPadding(dp(12),dp(20),dp(12),dp(20));root.addView(empty);list=new ListView(this);list.setDivider(null);list.setVerticalScrollBarEnabled(false);root.addView(list,new LinearLayout.LayoutParams(-1,0,1));updateRemovedBack();IntentFilter filter=new IntentFilter(PersonalChangeSignal.ACTION);if(Build.VERSION.SDK_INT>=33)registerReceiver(changes,filter,Context.RECEIVER_NOT_EXPORTED);else registerReceiver(changes,filter);receiverRegistered=true;load();
 }
 private TextView text(String value,int size,int color){TextView v=new TextView(this);v.setText(value);v.setTextSize(size);v.setTextColor(color);return v;}
 private Button button(String title,Runnable action){Button b=new Button(this);b.setText(title);b.setTextSize(15);b.setAllCaps(false);b.setTextColor(Ui.accent(this));b.setMinWidth(0);b.setMinimumWidth(0);b.setMinHeight(0);b.setMinimumHeight(0);b.setMaxLines(1);b.setHorizontallyScrolling(false);b.setPadding(dp(4),0,dp(4),0);Ui.pressable(b,Color.TRANSPARENT,10);b.setOnClickListener(v->{if(!busy)action.run();});return b;}
 private void load(){worker.execute(()->{try{PersonalLexicon.Snapshot next=store.load();Set<String> valid=readSyllables();runOnUiThread(()->{if(isFinishing()||isDestroyed())return;state=next;syllables=valid;refresh();});}catch(Exception error){runOnUiThread(()->{empty.setText("暂时无法读取词库，原文件已保留。");more.setEnabled(false);add.setEnabled(false);});}});}
 private void refresh(){if(state==null||list==null)return;if(getActionBar()!=null)getActionBar().setTitle(removed?"已移除的词条":"个人词库与短语");updateRemovedBack();add.setVisibility(removed?View.GONE:View.VISIBLE);
  String needle=query.trim().toLowerCase(Locale.ROOT);List<PersonalLexicon.Entry> entries=new ArrayList<>();for(PersonalLexicon.Entry entry:removed?state.removed():state.entries)if(needle.isEmpty()||entry.text.toLowerCase(Locale.ROOT).contains(needle)||entry.trigger.toLowerCase(Locale.ROOT).contains(needle))entries.add(entry);
  empty.setText(!needle.isEmpty()?"没有匹配项":removed?"没有已移除的词条":"还没有词条或快捷短语");empty.setVisibility(entries.isEmpty()?View.VISIBLE:View.GONE);

  list.setAdapter(new BaseAdapter(){public int getCount(){return entries.size();}public Object getItem(int i){return entries.get(i);}public long getItemId(int i){return i;}public View getView(int position,View old,ViewGroup parent){PersonalLexicon.Entry entry=entries.get(position);LinearLayout row=old instanceof LinearLayout?(LinearLayout)old:new LinearLayout(PersonalLexiconActivity.this);row.removeAllViews();row.setOrientation(1);row.setPadding(dp(16),dp(12),dp(16),dp(12));Ui.pressable(row,Ui.surface(PersonalLexiconActivity.this),12);TextView content=text(entry.text,17,Ui.text(PersonalLexiconActivity.this));content.setMaxLines(2);content.setEllipsize(TextUtils.TruncateAt.END);row.addView(content);row.addView(text((entry.kind.equals("word")?"词条 · ":"短语 · ")+entry.trigger,13,Ui.muted(PersonalLexiconActivity.this)));row.setOnClickListener(v->{if(removed)restore(entry);else edit(entry);});return row;}});
 }
 private Set<String> readSyllables()throws IOException {
  Set<String> valid=new HashSet<>();try(BufferedReader input=new BufferedReader(new InputStreamReader(getAssets().open("pinyin-syllables.txt"),"UTF-8"))){String line;while((line=input.readLine())!=null)if(line.trim().matches("[a-z]+"))valid.add(line.trim());}
  if(valid.isEmpty())throw new IOException("拼音表暂不可用");return valid;
 }
 private void moreMenu(){
  if(state==null)return;PopupMenu menu=new PopupMenu(this,more);
  menu.getMenu().add("导入…").setOnMenuItemClickListener(item->{pickDocument(false);return true;});
  menu.getMenu().add("导出…").setEnabled(!state.entries.isEmpty()).setOnMenuItemClickListener(item->{pickDocument(true);return true;});
  if(removed||!state.removed().isEmpty())menu.getMenu().add(removed?"返回词库":"已移除（"+state.removed().size()+"）").setOnMenuItemClickListener(item->{removed=!removed;refresh();return true;});
  menu.show();
 }
 private void pickDocument(boolean exporting){
  Intent picker=new Intent(exporting?Intent.ACTION_CREATE_DOCUMENT:Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(exporting?"application/json":"*/*");
  if(exporting)picker.putExtra(Intent.EXTRA_TITLE,"灵鹤个人词库与短语.json");
  try{launchDocumentPicker(picker,exporting?302:301);}catch(ActivityNotFoundException missing){Toast.makeText(this,"系统文件选择器暂不可用",Toast.LENGTH_SHORT).show();}
 }
 protected void launchDocumentPicker(Intent intent,int request){startActivityForResult(intent,request);}
 @Override protected void onActivityResult(int request,int result,Intent data){
  super.onActivityResult(request,result,data);if((request!=301&&request!=302)||result!=RESULT_OK||data==null||data.getData()==null)return;
  android.net.Uri uri=data.getData();if(!"content".equals(uri.getScheme())){Toast.makeText(this,"请选择系统文件中的JSON词库",Toast.LENGTH_SHORT).show();return;}
  busy=true;more.setEnabled(false);add.setEnabled(false);
  worker.execute(()->{
   PersonalLexicon.Snapshot next=null;String message;
   try {
    if(request==301){String incoming;try(InputStream input=getContentResolver().openInputStream(uri)){incoming=LexiconDocuments.read(input);}next=store.importEntries(incoming,readSyllables());PersonalChangeSignal.notifyChanged(getApplicationContext());message="词库已合并";}
    else{String encoded=store.exportEntries();try(OutputStream output=getContentResolver().openOutputStream(uri,"wt")){LexiconDocuments.write(output,encoded);}message="词库已导出";}
   }catch(Exception failure){message=request==301?"无法导入，请检查文件格式与容量；原词库已保留":"导出失败，请重试";}
   final PersonalLexicon.Snapshot updated=next;final String status=message;
   runOnUiThread(()->{if(isFinishing()||isDestroyed())return;busy=false;more.setEnabled(true);add.setEnabled(true);if(updated!=null){state=updated;removed=false;refresh();}Toast.makeText(this,status,Toast.LENGTH_LONG).show();});
  });
 }
 private void returnFromRemoved(){removed=false;updateRemovedBack();refresh();}
 private void updateRemovedBack(){if(removed){if(removedBack==null)removedBack=SettingsScreen.interceptBack(this,this::returnFromRemoved);}else if(removedBack!=null){SettingsScreen.releaseBack(this,removedBack);removedBack=null;}}
 @Override public boolean onOptionsItemSelected(MenuItem item){if(item.getItemId()==android.R.id.home){if(!busy){if(removed)returnFromRemoved();else finish();}return true;}return super.onOptionsItemSelected(item);}
 @Override public void onBackPressed(){if(removed)returnFromRemoved();else super.onBackPressed();}
 @Override protected void onSaveInstanceState(Bundle state){state.putBoolean("removed",removed);state.putString("query",query);super.onSaveInstanceState(state);}
 private EditText field(String hint,boolean multiline){EditText v=new EditText(this);v.setHint(hint);v.setTextSize(17);v.setTextColor(Ui.text(this));v.setInputType(android.text.InputType.TYPE_CLASS_TEXT|(multiline?android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE:0));v.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);v.setSingleLine(!multiline);v.setMaxLines(multiline?5:1);return v;}
 private void edit(PersonalLexicon.Entry entry){if(state==null||syllables==null)return;LinearLayout box=new LinearLayout(this);box.setOrientation(1);box.setPadding(dp(20),dp(6),dp(20),dp(10));RadioGroup kinds=new RadioGroup(this);kinds.setOrientation(0);RadioButton word=new RadioButton(this);word.setId(3000);word.setText("个人词条");RadioButton phrase=new RadioButton(this);phrase.setId(3001);phrase.setText("快捷短语");kinds.addView(word);kinds.addView(phrase);kinds.check(entry!=null&&entry.kind.equals("phrase")?3001:3000);box.addView(kinds);
  EditText value=field("内容",true),trigger=field(kinds.getCheckedRadioButtonId()==3000?"拼音，例如 ling he":"缩写，例如 dz",false);box.addView(value,new LinearLayout.LayoutParams(-1,dp(112)));box.addView(trigger,new LinearLayout.LayoutParams(-1,dp(56)));kinds.setOnCheckedChangeListener((g,id)->trigger.setHint(id==3000?"拼音，例如 ling he":"缩写，例如 dz"));if(entry!=null){value.setText(entry.text);trigger.setText(entry.trigger);}
  AlertDialog.Builder builder=new AlertDialog.Builder(this).setTitle(entry==null?"新增词条":"编辑词条").setView(box).setNegativeButton("取消",null).setPositiveButton("保存",null);if(entry!=null)builder.setNeutralButton("移除",null);AlertDialog dialog=builder.create();dialog.setOnShowListener(d->{dialog.getButton(-1).setOnClickListener(v->{PersonalLexicon.Entry next=new PersonalLexicon.Entry(entry==null?UUID.randomUUID().toString():entry.id,kinds.getCheckedRadioButtonId()==3000?"word":"phrase",value.getText().toString(),PersonalLexicon.normalize(trigger.getText().toString()));try{next.validate(syllables);}catch(Exception invalid){trigger.setError(invalid.getMessage());return;}dialog.getButton(-1).setEnabled(false);worker.execute(()->{try{PersonalLexicon.Snapshot updated=store.upsert(next,syllables);PersonalChangeSignal.notifyChanged(getApplicationContext());runOnUiThread(()->{state=updated;removed=false;refresh();dialog.dismiss();});}catch(Exception failure){runOnUiThread(()->{dialog.getButton(-1).setEnabled(true);trigger.setError("保存失败，原词库已保留");});}});});if(entry!=null)dialog.getButton(-3).setOnClickListener(v->{dialog.dismiss();remove(entry);});});Ui.dialog(dialog);
 }
 private void remove(PersonalLexicon.Entry entry){Ui.dialog(new AlertDialog.Builder(this).setTitle("移除此词条？").setMessage("可在“已移除”中恢复。").setNegativeButton("取消",null).setPositiveButton("移除",(d,w)->worker.execute(()->{try{PersonalLexicon.Snapshot next=store.remove(entry.id);PersonalChangeSignal.notifyChanged(getApplicationContext());runOnUiThread(()->{state=next;refresh();});}catch(Exception error){runOnUiThread(()->Toast.makeText(this,"未能移除，原词库已保留",Toast.LENGTH_SHORT).show());}})).create());}
 private void restore(PersonalLexicon.Entry entry){Ui.dialog(new AlertDialog.Builder(this).setTitle("恢复词条").setMessage(entry.text).setNegativeButton("取消",null).setPositiveButton("恢复",(d,w)->worker.execute(()->{try{PersonalLexicon.Snapshot next=store.upsert(entry,null);PersonalChangeSignal.notifyChanged(getApplicationContext());runOnUiThread(()->{state=next;removed=false;refresh();});}catch(Exception error){runOnUiThread(()->Toast.makeText(this,"恢复失败，原词库已保留",Toast.LENGTH_SHORT).show());}})).create());}
 @Override public void onDestroy(){SettingsScreen.releaseBack(this,removedBack);removedBack=null;if(receiverRegistered){unregisterReceiver(changes);receiverRegistered=false;}super.onDestroy();worker.shutdown();}
}
