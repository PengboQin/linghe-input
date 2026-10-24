package live.linghe.privateinput;

import android.view.inputmethod.ExtractedText;
import android.view.inputmethod.ExtractedTextRequest;
import android.view.inputmethod.InputConnection;

/** Bounded, synchronous host readback. Unsupported/partial snapshots fail closed. */
final class SymbolPairInputConnection {
 static boolean beginBatch(InputConnection connection){try{return connection.beginBatchEdit();}catch(RuntimeException unavailable){return false;}}
 static void endBatch(InputConnection connection){try{connection.endBatchEdit();}catch(RuntimeException unavailable){}}
 static boolean moveCaret(InputConnection connection,int back){
  SymbolPairing.Snapshot current=read(connection);
  if(current==null||!current.collapsed()||current.start<back)return false;
  try{return connection.setSelection(current.start-back,current.start-back);}catch(RuntimeException unavailable){return false;}
 }
 static SymbolPairing.Snapshot read(InputConnection connection){
  if(connection==null)return null;
  try{
   ExtractedTextRequest request=new ExtractedTextRequest();request.hintMaxChars=SymbolPairing.Snapshot.WINDOW*2+4;request.hintMaxLines=4;
   ExtractedText text=connection.getExtractedText(request,0);
   if(text==null||text.text==null||text.startOffset<0||text.partialStartOffset>=0||text.partialEndOffset>=0||text.selectionStart<0||text.selectionEnd<text.selectionStart||text.selectionEnd>text.text.length())return null;
   int start=text.startOffset+text.selectionStart,end=text.startOffset+text.selectionEnd;
   if(start<text.startOffset||end<start)return null;
   String before=text.text.subSequence(Math.max(0,text.selectionStart-SymbolPairing.Snapshot.WINDOW),text.selectionStart).toString();
   String after=text.text.subSequence(text.selectionEnd,Math.min(text.text.length(),text.selectionEnd+SymbolPairing.Snapshot.WINDOW)).toString();
   // A truncated extraction must still supply the complete requested local
   // windows; otherwise changing extraction windows could hide a local edit.
   if(text.startOffset>0&&before.length()<SymbolPairing.Snapshot.WINDOW)return null;
   return new SymbolPairing.Snapshot(start,end,before,after);
  }catch(RuntimeException unavailable){return null;}
 }
 /** true means handled/uncertain; never retry an edit after scope loss or an own-pair attempt. */
 static boolean erase(SymbolPairing.Tracker tracker,InputConnection connection,int document,boolean enabled,java.util.function.BooleanSupplier sameEditor){
  if(!enabled){tracker.invalidate();return false;}
  if(!tracker.hasReceipt())return false;
  if(!sameEditor.getAsBoolean()){tracker.invalidate();return true;}
  SymbolPairing.Deletion deletion=tracker.take(document,connection,read(connection),enabled);
  if(!sameEditor.getAsBoolean()){tracker.invalidate();return true;}
  if(deletion==null)return false;
  if(!tracker.active(deletion))return true;
  try{connection.deleteSurroundingTextInCodePoints(deletion.before,deletion.after);}catch(RuntimeException unavailable){/* Do not double-delete after an uncertain host result. */}
  return true;
 }
}
