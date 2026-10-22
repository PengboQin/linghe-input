package live.linghe.privateinput;

/** One completed tap, never a drag, cancellation or second pointer. */
final class TapReleaseState {
 private boolean down,cancelled;
 void begin(){down=true;cancelled=false;}
 void move(float x,float y,int width,int height,int slop){if(x < -slop||y < -slop||x >= width+slop||y >= height+slop)cancelled=true;}
 void cancel(){down=false;cancelled=true;}
 boolean finish(float x,float y,int width,int height){boolean click=down&&!cancelled&&x>=0&&y>=0&&x<width&&y<height;down=false;return click;}
}
