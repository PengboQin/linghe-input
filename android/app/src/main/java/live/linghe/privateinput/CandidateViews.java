package live.linghe.privateinput;

import android.content.Context;
import android.graphics.Color;
import android.text.TextPaint;
import android.view.*;
import android.widget.*;
import java.util.*;
import java.util.function.Consumer;
import java.util.function.BiConsumer;

/** Native scrolling/recycling; data uses stable IDs, never view positions. */
final class CandidateViews {
 /** Reserve the longest ordinary syllable before typing starts, so filtering
  * never changes the main key widths mid-composition. Font scaling is measured,
  * and narrow displays retain at least three usable columns beside the rail. */
 static int pinyinRailWidth(Context c,int availableWidth){
  TextPaint paint=new TextPaint();paint.setTypeface(android.graphics.Typeface.DEFAULT);
  paint.setTextSize(15*c.getResources().getDisplayMetrics().scaledDensity);
  float longest=Math.max(paint.measureText("zhuang"),paint.measureText("shuang"));
  int needed=(int)Math.ceil(longest)+Ui.dp(c,12);
  int limit=Math.max(Ui.dp(c,64),Math.min(Ui.dp(c,96),(int)(availableWidth*0.24f)));
  return Math.max(Ui.dp(c,64),Math.min(limit,needed));
 }
 static void pinyinRailButton(KeyboardButton value){
  value.setGravity(Gravity.CENTER);value.setPadding(Ui.dp(value.getContext(),6),0,Ui.dp(value.getContext(),6),0);value.setTextSize(15);value.setSingleLine(true);
  value.setHorizontallyScrolling(false);value.setEllipsize(null);
  value.setAutoSizeTextTypeUniformWithConfiguration(11,15,1,android.util.TypedValue.COMPLEX_UNIT_SP);
 }
 static final class Item {
  final String id,text,reading;
  Item(String[] row){id=row[0];text=row[1];reading=row.length>2?row[2]:"";}
 }
 static Button word(Context c,Item item,Consumer<Item> select){return word(c,item,select,null);}
 static Button word(Context c,Item item,Consumer<Item> select,BiConsumer<View,Item> manage){
  Button b=new Button(c);b.setText(item.text);b.setTextSize(18);b.setAllCaps(false);b.setTypeface(android.graphics.Typeface.DEFAULT);b.setTextColor(Ui.text(c));b.setMinWidth(0);b.setMinimumWidth(0);b.setMinHeight(Ui.dp(c,44));b.setMinimumHeight(Ui.dp(c,44));b.setPadding(Ui.dp(c,10),0,Ui.dp(c,10),0);Ui.pressable(b,Color.TRANSPARENT,8);b.setClipToOutline(true);b.setOnClickListener(v->select.accept(item));if(manage!=null&&!item.id.startsWith("custom:")&&!item.id.startsWith("english:")&&!item.id.startsWith("continuation:")&&!item.reading.trim().isEmpty()&&item.reading.matches("[a-zA-Z ']+"))b.setOnLongClickListener(v->{manage.accept(v,item);return true;});return b;
 }
 static final class Strip extends HorizontalScrollView {
  private final FrameLayout content;private final LinearLayout visible;
  private final Consumer<Item> select;private final BiConsumer<View,Item> manage;private final Runnable more;private final Runnable interaction;private final TextPaint paint=new TextPaint();
  private List<Item> items=Collections.emptyList();private final ArrayList<Integer> edges=new ArrayList<>();
  private int first=-1,last=-1;private final int textPadding;private boolean updating,touching;private List<Item> deferred;private boolean deferredReset;
  private final Runnable drain=()->{if(deferred!=null&&!touching){List<Item> next=deferred;boolean reset=deferredReset;deferred=null;deferredReset=false;update(next,reset);}};
  private final Runnable layoutUpdate=()->{bind();maybeMore();};private final Runnable requestMore=this::maybeMore;
  Strip(Context c,Consumer<Item> select,Runnable more){this(c,select,more,()->{});}
  Strip(Context c,Consumer<Item> select,Runnable more,Runnable interaction){this(c,select,more,interaction,null);}
  Strip(Context c,Consumer<Item> select,Runnable more,Runnable interaction,BiConsumer<View,Item> manage){super(c);this.select=select;this.manage=manage;this.more=more;this.interaction=interaction;setHorizontalScrollBarEnabled(false);setFillViewport(true);content=new FrameLayout(c);visible=new LinearLayout(c);content.addView(visible);addView(content,new LayoutParams(0,Ui.dp(c,48)));Button sample=word(c,new Item(new String[]{"sample","字",""}),item->{});paint.set(sample.getPaint());textPadding=sample.getCompoundPaddingLeft()+sample.getCompoundPaddingRight()+Ui.dp(c,8);edges.add(0);setContentDescription("候选词，可左右滑动");}
  void update(List<Item> next,boolean reset){
   if(touching){deferred=new ArrayList<>(next);deferredReset|=reset;return;}
   List<Item> owned=Collections.unmodifiableList(new ArrayList<>(next));boolean append=!reset&&items.size()<=owned.size();
   if(append)for(int i=0;i<items.size();i++){Item a=items.get(i),b=owned.get(i);if(!a.id.equals(b.id)||!a.text.equals(b.text)||!a.reading.equals(b.reading)){append=false;break;}}
   updating=true;
   try {
    items=owned;if(!append){edges.clear();edges.add(0);first=last=-1;}
    for(int i=edges.size()-1;i<items.size();i++){
     int cap=items.get(i).id.startsWith("clipboard:")?220:800;
     int width=Math.max(Ui.dp(getContext(),44),Math.min(Ui.dp(getContext(),cap),(int)Math.ceil(paint.measureText(items.get(i).text))+textPadding));
     edges.add(edges.get(edges.size()-1)+width);
    }
    content.setMinimumWidth(edges.get(edges.size()-1));content.setLayoutParams(new LayoutParams(edges.get(edges.size()-1),Ui.dp(getContext(),48)));if(!append)scrollTo(0,0);
   }finally{updating=false;}
   bind();removeCallbacks(requestMore);post(requestMore);
  }
  private int at(int x){int low=0,high=items.size();while(low<high){int mid=(low+high)/2;if(edges.get(mid+1)<=x)low=mid+1;else high=mid;}return Math.min(low,Math.max(0,items.size()-1));}
  private void bind(){if(updating)return;if(items.isEmpty()){visible.removeAllViews();first=last=-1;return;}int width=Math.max(getWidth(),Ui.dp(getContext(),320));int a=at(Math.max(0,getScrollX()-width)),b=at(getScrollX()+width*2)+1;
   if(first==a&&last==b)return;int appendFrom=first==a&&last>=a&&b>last?last:a;if(appendFrom==a)visible.removeAllViews();first=a;last=b;FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(-2,Ui.dp(getContext(),48));lp.leftMargin=edges.get(a);visible.setLayoutParams(lp);
   for(int i=appendFrom;i<b;i++){Button key=word(getContext(),items.get(i),select,manage);key.setMaxLines(1);key.setHorizontallyScrolling(false);key.setEllipsize(android.text.TextUtils.TruncateAt.END);visible.addView(key,new LinearLayout.LayoutParams(edges.get(i+1)-edges.get(i),-1));}
  }
  private void maybeMore(){if(!updating&&getWidth()>0&&getScrollX()+getWidth()*2>=edges.get(edges.size()-1))more.run();}
  @Override public boolean dispatchTouchEvent(MotionEvent event){int phase=event.getActionMasked();if(phase==MotionEvent.ACTION_DOWN){touching=true;interaction.run();}boolean result=super.dispatchTouchEvent(event);if(phase==MotionEvent.ACTION_UP||phase==MotionEvent.ACTION_CANCEL){touching=false;removeCallbacks(drain);post(drain);}return result;}
  @Override protected void onScrollChanged(int x,int y,int ox,int oy){super.onScrollChanged(x,y,ox,oy);bind();maybeMore();}
  @Override protected void onSizeChanged(int w,int h,int oldw,int oldh){super.onSizeChanged(w,h,oldw,oldh);removeCallbacks(layoutUpdate);if(isAttachedToWindow())post(layoutUpdate);else bind();}
  @Override protected void onDetachedFromWindow(){removeCallbacks(layoutUpdate);removeCallbacks(requestMore);removeCallbacks(drain);touching=false;deferred=null;super.onDetachedFromWindow();}
 }
 static final class Expanded extends ListView {
  private final Rows rows;private final Runnable more,interaction;private boolean touching;private List<Item> deferred;
  private final Runnable drain=()->{if(deferred!=null&&!touching){List<Item> next=deferred;deferred=null;update(next);}};
  Expanded(Context c,Consumer<Item> select,Runnable more){this(c,select,more,()->{});}
  Expanded(Context c,Consumer<Item> select,Runnable more,Runnable interaction){this(c,select,more,interaction,null);}
  Expanded(Context c,Consumer<Item> select,Runnable more,Runnable interaction,BiConsumer<View,Item> manage){super(c);this.more=more;this.interaction=interaction;setDivider(null);setVerticalScrollBarEnabled(false);setSelector(android.R.color.transparent);rows=new Rows(c,select,manage);setAdapter(rows);setOnScrollListener(new AbsListView.OnScrollListener(){public void onScrollStateChanged(AbsListView v,int state){}public void onScroll(AbsListView v,int first,int visible,int total){if(total>0&&first+visible>=total-3)Expanded.this.more.run();}});}
  @Override public boolean dispatchTouchEvent(MotionEvent event){int phase=event.getActionMasked();if(phase==MotionEvent.ACTION_DOWN){touching=true;interaction.run();}boolean result=super.dispatchTouchEvent(event);if(phase==MotionEvent.ACTION_UP||phase==MotionEvent.ACTION_CANCEL){touching=false;removeCallbacks(drain);post(drain);}return result;}
  void update(List<Item> items){if(touching){deferred=new ArrayList<>(items);return;}rows.update(items);}
  @Override protected void onDetachedFromWindow(){removeCallbacks(drain);touching=false;deferred=null;super.onDetachedFromWindow();}
 }
 private static final class Cell{final Item item;final int span;Cell(Item item,int span){this.item=item;this.span=span;}}
 private static final class Rows extends BaseAdapter {
  private final Context context;private final Consumer<Item> select;private final BiConsumer<View,Item> manage;private final ArrayList<ArrayList<Cell>> rows=new ArrayList<>();
  Rows(Context c,Consumer<Item> select,BiConsumer<View,Item> manage){context=c;this.select=select;this.manage=manage;}
  void update(List<Item> items){rows.clear();ArrayList<Cell> row=new ArrayList<>();int column=0;
   for(Item item:items){int length=item.text.codePointCount(0,item.text.length());int span=length>6?4:length>3?2:1;if(column+span>4){rows.add(row);row=new ArrayList<>();column=0;}row.add(new Cell(item,span));column+=span;if(column==4){rows.add(row);row=new ArrayList<>();column=0;}}
   if(!row.isEmpty())rows.add(row);notifyDataSetChanged();
  }
  public int getCount(){return rows.size();}public Object getItem(int i){return rows.get(i);}public long getItemId(int i){return i;}
  public View getView(int position,View recycled,ViewGroup parent){LinearLayout line=recycled instanceof LinearLayout?(LinearLayout)recycled:new LinearLayout(context);line.removeAllViews();int used=0;
   for(Cell cell:rows.get(position)){Button b=word(context,cell.item,select,manage);b.setGravity(cell.span==4?Gravity.START|Gravity.CENTER_VERTICAL:Gravity.CENTER);b.setPadding(Ui.dp(context,6),Ui.dp(context,8),Ui.dp(context,6),Ui.dp(context,8));line.addView(b,new LinearLayout.LayoutParams(0,-2,cell.span));used+=cell.span;}
   if(used<4)line.addView(new View(context),new LinearLayout.LayoutParams(0,1,4-used));return line;
  }
 }
}
