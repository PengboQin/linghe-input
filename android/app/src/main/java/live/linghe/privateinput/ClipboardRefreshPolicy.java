package live.linghe.privateinput;
/** No clipboard body. A metadata heartbeat repairs missed platform listeners. */
final class ClipboardRefreshPolicy {
 private String last;private boolean observed;
 boolean changed(String stamp,boolean listener){
  boolean read=listener||!observed||stamp==null||!stamp.equals(last);
  observed=true;last=stamp;return read;
 }
 void reset(){last=null;observed=false;}
}
