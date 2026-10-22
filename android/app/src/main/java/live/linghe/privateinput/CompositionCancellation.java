package live.linghe.privateinput;
import android.view.inputmethod.InputConnection;
/** Cancel only the IME-owned composing span. Never delete surrounding committed text. */
final class CompositionCancellation {
 static boolean cancel(InputConnection connection,boolean marked){if(!marked||connection==null)return false;try{boolean cleared=connection.setComposingText("",1);connection.finishComposingText();return cleared;}catch(RuntimeException unavailable){return false;}}
}
