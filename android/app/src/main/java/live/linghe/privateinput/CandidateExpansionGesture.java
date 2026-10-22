package live.linghe.privateinput;

import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;

/** Deliver on release before KeyboardRoot drains its deferred render. Native
 * Button's posted click can otherwise be removed with a replaced header view. */
final class CandidateExpansionGesture implements View.OnTouchListener,View.OnAttachStateChangeListener {
 private final TapReleaseState tap=new TapReleaseState();
 private final Runnable began;
 private final int slop;
 CandidateExpansionGesture(View key,Runnable began){this.began=began;slop=ViewConfiguration.get(key.getContext()).getScaledTouchSlop();key.setOnTouchListener(this);key.addOnAttachStateChangeListener(this);}
 public boolean onTouch(View key,MotionEvent e){
  if(!key.isEnabled()){tap.cancel();key.setPressed(false);return true;}
  switch(e.getActionMasked()){
   case MotionEvent.ACTION_DOWN:tap.begin();key.setPressed(true);began.run();return true;
   case MotionEvent.ACTION_MOVE:tap.move(e.getX(),e.getY(),key.getWidth(),key.getHeight(),slop);return true;
   case MotionEvent.ACTION_UP:boolean click=tap.finish(e.getX(),e.getY(),key.getWidth(),key.getHeight());key.setPressed(false);if(click)key.performClick();return true;
   case MotionEvent.ACTION_POINTER_DOWN:case MotionEvent.ACTION_CANCEL:tap.cancel();key.setPressed(false);return true;
   default:return true;
  }
 }
 public void onViewDetachedFromWindow(View key){tap.cancel();key.setPressed(false);}
 public void onViewAttachedToWindow(View key){}
}
