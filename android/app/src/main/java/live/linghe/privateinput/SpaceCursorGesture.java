package live.linghe.privateinput;

import android.os.*;
import android.view.*;
import java.util.function.IntConsumer;

/** A tap clicks once; holding for 350 ms turns horizontal travel into cursor steps. */
final class SpaceCursorGesture implements View.OnTouchListener,View.OnAttachStateChangeListener {
 private final View key;private final Handler handler=new Handler(Looper.getMainLooper());
 private final Runnable began,ended;private final IntConsumer move;
 private float originX,originY;private int steps;private boolean down,active,cancelled;
 private final float unit,slop;private final Runnable hold;
 SpaceCursorGesture(View key,Runnable began,IntConsumer move,Runnable ended) {
  this.key=key;this.began=began;this.move=move;this.ended=ended;
  hold=()->{if(down&&!cancelled){active=true;key.setPressed(true);began.run();}};
  unit=key.getResources().getDisplayMetrics().density*9;
  slop=ViewConfiguration.get(key.getContext()).getScaledTouchSlop();
  key.setOnTouchListener(this);key.addOnAttachStateChangeListener(this);
  key.setContentDescription("空格，按住后左右滑动移动光标");
 }
 private void stop(){handler.removeCallbacks(hold);down=false;key.setPressed(false);if(active)ended.run();active=false;}
 @Override public boolean onTouch(View view,MotionEvent event) {
  switch(event.getActionMasked()) {
   case MotionEvent.ACTION_DOWN:
    stop();originX=event.getX();originY=event.getY();steps=0;down=true;cancelled=false;key.setPressed(true);handler.postDelayed(hold,350);return true;
   case MotionEvent.ACTION_MOVE:
    if(!down)return true;
    if(!active&&(Math.abs(event.getX()-originX)>slop||Math.abs(event.getY()-originY)>slop)){cancelled=true;handler.removeCallbacks(hold);key.setPressed(false);}
    if(active){int target=Math.max(-256,Math.min(256,(int)((event.getX()-originX)/unit)));int delta=target-steps;if(delta!=0){steps=target;move.accept(delta);}}return true;
   case MotionEvent.ACTION_UP:
    boolean click=down&&!active&&!cancelled;stop();if(click)key.performClick();return true;
   case MotionEvent.ACTION_CANCEL:case MotionEvent.ACTION_POINTER_DOWN:stop();cancelled=true;return true;
   default:return true;
  }
 }
 @Override public void onViewDetachedFromWindow(View view){stop();}
 @Override public void onViewAttachedToWindow(View view){}
}
