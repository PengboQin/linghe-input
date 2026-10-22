package live.linghe.privateinput;

/** UI-only admission; clipboard delivery is independent and remains silent.
 * A copy observed while busy is discarded, never scheduled for a later prompt. */
final class ClipboardPresentationPolicy {
 static final long IDLE_AFTER_EDIT_MS=700;
 private long lastEdit=-1;
 void edited(long uptime){lastEdit=uptime;}
 boolean idle(boolean safe,boolean composing,int queued,boolean pressed,boolean englishWord,boolean deleteHeld,long uptime){
  // A language-prediction deletion latch is intentionally not an input. New
  // copies may display after editing settles without reviving the old copy.
  return safe&&!composing&&queued==0&&!pressed&&!englishWord&&!deleteHeld&&
   (lastEdit<0||uptime>=lastEdit&&uptime-lastEdit>=IDLE_AFTER_EDIT_MS);
 }
}
