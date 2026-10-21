package live.linghe.privateinput;
import android.content.Context;
import android.widget.EditText;

/** Only an explicit native paste into this app's own enabled editor is a paste fact. */
final class ActivityArchiveEditText extends EditText {
  boolean archivePaste;
  ActivityArchiveEditText(Context context){super(context);}
  @Override public boolean onTextContextMenuItem(int action){
    boolean observe=archivePaste&&(action==android.R.id.paste||action==android.R.id.pasteAsPlainText)
      &&ActivityArchiveManager.get(getContext()).pasteAllowed()
      &&ActivityArchiveRules.safeInput(getInputType(),getImeOptions(),true);
    String before=observe?getText().toString():null;int start=getSelectionStart(),end=getSelectionEnd();
    boolean result=super.onTextContextMenuItem(action);
    if(observe&&result&&start>=0&&end>=0){
      int first=Math.min(start,end),last=Math.max(start,end);String after=getText().toString();
      String prefix=before.substring(0,first),suffix=before.substring(last);
      if(after.length()>=prefix.length()+suffix.length()&&after.startsWith(prefix)&&after.endsWith(suffix)){
        String inserted=after.substring(prefix.length(),after.length()-suffix.length());
        if(!inserted.isEmpty())ActivityArchiveManager.get(getContext()).explicitPaste(inserted,true);
      }
    }return result;
  }
}
