package live.linghe.privateinput;
import android.content.Context;
import android.graphics.*;
import android.widget.Button;
import android.view.MotionEvent;
/** Draw keyboard controls independently of font-dependent Unicode arrow glyphs. */
final class KeyboardButton extends Button {
  static final int TEXT=0,HIDE=1,EXPAND=2,COLLAPSE=3;
  int glyph=TEXT;
  boolean opticalCenter=false;
  private Runnable action,pendingAction;private boolean touchCaptured;
  private final Runnable clearPending=()->{pendingAction=null;touchCaptured=false;};
  void setKeyboardAction(Runnable next){action=next;}
  @Override public boolean dispatchTouchEvent(MotionEvent event){int phase=event.getActionMasked();if(phase==MotionEvent.ACTION_DOWN){removeCallbacks(clearPending);pendingAction=action;touchCaptured=true;}if(phase==MotionEvent.ACTION_CANCEL){pendingAction=null;touchCaptured=false;}boolean handled=super.dispatchTouchEvent(event);if(phase==MotionEvent.ACTION_UP||phase==MotionEvent.ACTION_CANCEL)post(clearPending);return handled;}
  @Override protected void onDetachedFromWindow(){removeCallbacks(clearPending);pendingAction=null;touchCaptured=false;super.onDetachedFromWindow();}
  KeyboardButton(Context context){
    super(context);
    setGravity(android.view.Gravity.CENTER);
    setIncludeFontPadding(false);
    setOnClickListener(view->{Runnable selected=touchCaptured?pendingAction:action;pendingAction=null;touchCaptured=false;if(selected!=null)selected.run();});
  }
  @Override protected void onDraw(Canvas canvas){
    if(glyph==TEXT&&!opticalCenter){
      super.onDraw(canvas);
      return;
    }
    Paint p=new Paint(getPaint());
    p.setColor(getCurrentTextColor());
    p.setAntiAlias(true);
    if(glyph==TEXT){
      String value=getText().toString();
      Rect bounds=new Rect();
      p.getTextBounds(value,0,value.length(),bounds);
      canvas.drawText(value,(getWidth()-bounds.left-bounds.right)/2f,(getHeight()-bounds.top-bounds.bottom)/2f,p);
      return;
    }
    float unit=Ui.dp(getContext(),1);
    canvas.save();
    canvas.translate(getWidth()/2f,getHeight()/2f);
    canvas.scale(unit,unit);
    p.setStyle(Paint.Style.STROKE);
    p.setStrokeWidth(1.8f);
    p.setStrokeCap(Paint.Cap.ROUND);
    p.setStrokeJoin(Paint.Join.ROUND);
    Path path=new Path();
    if(glyph==HIDE){
      canvas.drawRoundRect(-11,-10,11,3,2,2,p);
      for(int row=0;row<2;row++)for(int col=0;col<4;col++)canvas.drawPoint(-7+col*4.5f,-6+row*4,p);
      canvas.drawLine(-5,0,5,0,p);
      path.moveTo(-5,8);
      path.lineTo(0,12);
      path.lineTo(5,8);
    }
    else {
      float sign=glyph==COLLAPSE?-1:1;
      path.moveTo(-6,-3*sign);
      path.lineTo(0,3*sign);
      path.lineTo(6,-3*sign);
    }
    canvas.drawPath(path,p);
    canvas.restore();
  }
}
