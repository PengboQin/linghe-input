package live.linghe.privateinput;

import android.content.Context;
import android.view.MotionEvent;
import android.view.ViewConfiguration;
import android.widget.ScrollView;

/** One native vertical scrolling surface, including button margins and edges. */
final class KeyboardScrollView extends ScrollView {
 private final int slop;
 private boolean tracking;
 private float downX,downY;
 KeyboardScrollView(Context context){
  super(context);slop=ViewConfiguration.get(context).getScaledTouchSlop();
  setFillViewport(true);setVerticalScrollBarEnabled(false);setHorizontalScrollBarEnabled(false);
  setPadding(0,0,0,0);setClipToPadding(true);setOverScrollMode(OVER_SCROLL_NEVER);
 }
 @Override public boolean dispatchTouchEvent(MotionEvent event){
  int phase=event.getActionMasked();
  if(phase==MotionEvent.ACTION_DOWN){tracking=true;downX=event.getX();downY=event.getY();}
  // All children are keyboard buttons. A vertical drag belongs to their whole
  // parent surface, never to a child that asks to keep a pressed gesture.
  if(tracking&&phase==MotionEvent.ACTION_MOVE&&verticalDrag(event))super.requestDisallowInterceptTouchEvent(false);
  boolean handled=super.dispatchTouchEvent(event);
  if(phase==MotionEvent.ACTION_UP||phase==MotionEvent.ACTION_CANCEL)tracking=false;
  return handled;
 }
 private boolean verticalDrag(MotionEvent event){return Math.abs(event.getY()-downY)>slop&&Math.abs(event.getY()-downY)>=Math.abs(event.getX()-downX);}
 @Override public boolean onInterceptTouchEvent(MotionEvent event){
  boolean nativeIntercept=super.onInterceptTouchEvent(event);
  // Calling the native recognizer first keeps its velocity, pointer and slop
  // state. Framework interception sends CANCEL to the pressed button exactly
  // once; ScrollView itself performs scrolling and fling, not a second mover.
  return nativeIntercept||tracking&&event.getActionMasked()==MotionEvent.ACTION_MOVE&&verticalDrag(event);
 }
 @Override protected void onDetachedFromWindow(){tracking=false;super.onDetachedFromWindow();}
}
