package live.linghe.privateinput;

import android.app.*;import android.os.*;import android.content.*;import android.text.*;import android.view.*;import android.view.inputmethod.*;import android.widget.*;
import java.util.*;import java.util.concurrent.atomic.*;

/** Platform editable and real gesture recognizer, using only in-memory synthetic fields. */
public final class InputInteractionCheck extends Instrumentation {
 private int checks;private Throwable error;private Button space;private SpaceCursorGesture gesture;
 private final AtomicInteger clicks=new AtomicInteger(),moves=new AtomicInteger(),begins=new AtomicInteger(),ends=new AtomicInteger();
 private void require(boolean ok,String why){if(!ok)throw new AssertionError(why);}
 public void onCreate(Bundle args){super.onCreate(args);start();}
 private void ui(Runnable action){runOnMainSync(()->{try{action.run();}catch(Throwable e){error=e;}});if(error!=null)throw new AssertionError(error);}
 private void touch(int action,float x,float y){ui(()->{long time=SystemClock.uptimeMillis();MotionEvent event=MotionEvent.obtain(time,time,action,x,y,0);gesture.onTouch(space,event);event.recycle();});}
 private static final class Connection extends BaseInputConnection {
  final Editable text=new SpannableStringBuilder();boolean denyRegion,denyCommit;int deletes;
  Connection(View view,String value){super(view,true);text.append(value);Selection.setSelection(text,text.length());}
  @Override public Editable getEditable(){return text;}
  @Override public boolean setComposingRegion(int a,int b){return !denyRegion&&super.setComposingRegion(a,b);}
  @Override public boolean commitText(CharSequence value,int position){return !denyCommit&&super.commitText(value,position);}
  @Override public boolean deleteSurroundingText(int before,int after){deletes++;return super.deleteSurroundingText(before,after);}
 }
 public void onStart(){Bundle result=new Bundle();try{
  ui(()->{
   Context context=new ContextThemeWrapper(getTargetContext(),android.R.style.Theme_Material_Light);View view=new View(context);EnglishSuggestions lexicon=new EnglishSuggestions(Arrays.asList("hello","help","meeting","API"));EditorInfo info=new EditorInfo();info.inputType=InputType.TYPE_CLASS_TEXT;require(EnglishCompletion.allowed(info),"ordinary text allows completion");
   for(int variation:new int[]{InputType.TYPE_TEXT_VARIATION_URI,InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,InputType.TYPE_TEXT_VARIATION_PASSWORD,InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD}){info.inputType=InputType.TYPE_CLASS_TEXT|variation;require(!EnglishCompletion.allowed(info),"sensitive/special field excluded");}info.inputType=InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;require(!EnglishCompletion.allowed(info),"host suggestions opt out");checks++;
   Connection c=new Connection(view,"中文前文 hel");require(EnglishCompletion.prefix(c).equals("hel"),"only bounded current ASCII word");require(EnglishCompletion.choices(lexicon,"hel").equals(Arrays.asList("hello","help")),"completion order");require(EnglishCompletion.choices(lexicon,"HEL").equals(Arrays.asList("HELLO","HELP")),"upper case preserved");require(EnglishCompletion.choices(lexicon,"Hel").equals(Arrays.asList("Hello","Help")),"title case preserved");require(EnglishCompletion.choices(lexicon,"h").isEmpty(),"short prefix stays quiet");checks++;
   int end=c.text.length();require(EnglishCompletion.select(c,"hel","hello",end,end),"replace visible current word");require(c.text.toString().equals("中文前文 hello")&&c.deletes==0,"atomic composing replacement preserves surrounding text");require(BaseInputConnection.getComposingSpanStart(c.text)<0,"composing region cleared");checks++;
   c=new Connection(view,"中文前文 aoole 后文");int correctionEnd="中文前文 aoole".length();Selection.setSelection(c.text,correctionEnd);require(EnglishCompletion.select(c,"aoole","apple",correctionEnd,correctionEnd),"QWERTY correction is selectable");require(c.text.toString().equals("中文前文 apple 后文")&&c.deletes==0,"correction retains both surrounding sides with one composing replacement");checks++;
   android.content.SharedPreferences symbolPrefs=context.getSharedPreferences("parity15-symbols-"+System.nanoTime(),0);Symbols symbols=new Symbols(context);String[] seeds={".","@","-","+"};symbols.record("@",symbolPrefs);symbols.record("@",symbolPrefs);symbols.record(".",symbolPrefs);symbols.record("。",symbolPrefs);String[] numeric=symbols.rail(seeds,true,true,symbolPrefs);require(numeric[0].equals("@")&&numeric[1].equals(".")&&!Arrays.asList(numeric).contains("。"),"numeric rail learns halfwidth symbols without Chinese punctuation");require(symbols.rail(new String[]{"，","。","！","？"},false,true,symbolPrefs)[0].equals("@"),"nine-key rail also learns used symbols from the full catalog");require(Arrays.equals(symbols.rail(seeds,true,false,symbolPrefs),seeds),"private input uses defaults without personal symbol counts");symbolPrefs.edit().clear().commit();checks++;
   c=new Connection(view,"hello");Selection.setSelection(c.text,3);require(EnglishCompletion.prefix(c).isEmpty(),"inside word excluded");Selection.setSelection(c.text,0,3);require(EnglishCompletion.prefix(c).isEmpty(),"selection excluded");c=new Connection(view,String.join("",Collections.nCopies(33,"a")));require(EnglishCompletion.prefix(c).isEmpty(),"bounded oversized word");checks++;
   c=new Connection(view,"help");require(!EnglishCompletion.select(c,"hel","hello",4,4)&&c.text.toString().equals("help"),"stale prefix leaves text");c=new Connection(view,"hel");c.denyRegion=true;require(!EnglishCompletion.select(c,"hel","hello",3,3)&&c.text.toString().equals("hel"),"unsupported host leaves original text");c.denyRegion=false;c.denyCommit=true;require(!EnglishCompletion.select(c,"hel","hello",3,3)&&c.text.toString().equals("hel")&&c.deletes==0,"failed commit never predeletes word");checks++;
   ArrayList<CandidateViews.Item> source=new ArrayList<>();for(int i=0;i<9;i++)source.add(new CandidateViews.Item(new String[]{"old:"+i,"旧词"+i,""}));AtomicReference<String> selected=new AtomicReference<>();CandidateViews.Strip strip=new CandidateViews.Strip(context,item->selected.set(item.id),()->{});strip.update(source,true);int w=Ui.dp(context,320),h=Ui.dp(context,42);strip.measure(View.MeasureSpec.makeMeasureSpec(w,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(h,View.MeasureSpec.EXACTLY));strip.layout(0,0,w,h);source.clear();for(int i=0;i<96;i++)source.add(new CandidateViews.Item(new String[]{"new:"+i,"新词"+i,""}));strip.scrollTo(w*3,0);LinearLayout visible=(LinearLayout)((FrameLayout)strip.getChildAt(0)).getChildAt(0);visible.getChildAt(0).performClick();require(selected.get().startsWith("old:"),"detached/queued strip owns immutable list despite source growth");strip.update(source,false);source.clear();strip.scrollTo(w*2,0);visible=(LinearLayout)((FrameLayout)strip.getChildAt(0)).getChildAt(0);visible.getChildAt(0).performClick();require(selected.get().startsWith("new:"),"prefix replacement rebuilds edges and bindings before scrolling");strip.update(Collections.singletonList(new CandidateViews.Item(new String[]{"final","最终",""})),true);visible=(LinearLayout)((FrameLayout)strip.getChildAt(0)).getChildAt(0);visible.getChildAt(0).performClick();require(selected.get().equals("final")&&strip.getScrollX()==0,"scrolled strip shrink safely resets without reentrant index mismatch");checks++;
   for(float fontScale:new float[]{1f,1.3f,1.6f})for(int screenDp:new int[]{320,393,480}) {
    android.content.res.Configuration config=new android.content.res.Configuration(context.getResources().getConfiguration());config.fontScale=fontScale;
    Context scaled=new ContextThemeWrapper(context.createConfigurationContext(config),android.R.style.Theme_Material_Light);
    int available=Ui.dp(scaled,screenDp-8),railWidth=CandidateViews.pinyinRailWidth(scaled,available);
    require(railWidth>=Ui.dp(scaled,64)&&railWidth<=Ui.dp(scaled,96),"rail remains bounded without narrowing three primary columns excessively");
    for(String reading:new String[]{"meng","nong","zhong","zhuang","shuang","chuang"}) {
     KeyboardButton key=new KeyboardButton(scaled);key.setText(reading);key.setPadding(Ui.dp(scaled,2),0,Ui.dp(scaled,2),0);CandidateViews.pinyinRailButton(key);
     int height=Ui.dp(scaled,44);key.measure(View.MeasureSpec.makeMeasureSpec(railWidth,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));key.layout(0,0,railWidth,height);
     require(key.getLayout()!=null&&key.getLayout().getLineCount()==1,"long pinyin must remain a single line");
     require(key.getPaint().measureText(reading)<=railWidth-key.getCompoundPaddingLeft()-key.getCompoundPaddingRight()+1,"complete pinyin fits without clipping or ellipsis");
     require(key.getEllipsize()==null&&key.getGravity()==Gravity.CENTER,"pinyin is centered and not abbreviated");
    }
    checks++;
   }
   space=new Button(context);space.setOnClickListener(v->clicks.incrementAndGet());gesture=new SpaceCursorGesture(space,begins::incrementAndGet,moves::addAndGet,ends::incrementAndGet);
  });
  touch(MotionEvent.ACTION_DOWN,50,20);touch(MotionEvent.ACTION_UP,50,20);require(clicks.get()==1&&begins.get()==0,"short tap exactly once");checks++;
  touch(MotionEvent.ACTION_DOWN,50,20);touch(MotionEvent.ACTION_MOVE,500,20);touch(MotionEvent.ACTION_UP,500,20);require(clicks.get()==1&&begins.get()==0,"early swipe no stray space");checks++;
  touch(MotionEvent.ACTION_DOWN,50,20);SystemClock.sleep(420);float unit=getTargetContext().getResources().getDisplayMetrics().density*9;touch(MotionEvent.ACTION_MOVE,50+unit*3.1f,20);touch(MotionEvent.ACTION_UP,50+unit*3.1f,20);require(begins.get()==1&&moves.get()==3&&ends.get()==1&&clicks.get()==1,"hold moves three steps without space");checks++;
  touch(MotionEvent.ACTION_DOWN,50,20);touch(MotionEvent.ACTION_CANCEL,50,20);SystemClock.sleep(420);require(begins.get()==1&&clicks.get()==1,"cancel removes hold callback");checks++;
  result.putString("result","Passed");result.putInt("checks",checks);result.putBoolean("realUserDataTouched",false);result.putBoolean("systemTouchInjection",false);
 }catch(Throwable failure){result.putString("result","Failed");result.putInt("checksCompleted",checks);result.putString("error",failure.toString());}finally{if(gesture!=null)runOnMainSync(()->gesture.onViewDetachedFromWindow(space));}finish("Passed".equals(result.getString("result"))?-1:0,result);}
}
