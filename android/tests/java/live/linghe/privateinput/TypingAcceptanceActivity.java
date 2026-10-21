package live.linghe.privateinput;

import android.app.*;import android.os.*;import android.text.*;import android.view.*;import android.view.inputmethod.*;import android.widget.*;import java.io.*;import java.nio.charset.StandardCharsets;import java.util.*;import org.json.*;

/** Fresh synthetic editor, no access to the main application's files or learning. */
public final class TypingAcceptanceActivity extends Activity {
 private EditText field;private String nonce;
 private void report(){if(field==null||nonce==null)return;try{JSONObject report=new JSONObject().put("nonce",nonce).put("text",field.getText().toString()).put("start",field.getSelectionStart()).put("end",field.getSelectionEnd()).put("composingStart",BaseInputConnection.getComposingSpanStart(field.getText())).put("composingEnd",BaseInputConnection.getComposingSpanEnd(field.getText()));File target=new File(getExternalFilesDir(null),"typing-"+nonce+".json");try(OutputStream out=new FileOutputStream(target)){out.write(report.toString().getBytes(StandardCharsets.UTF_8));}}catch(Exception failure){throw new RuntimeException(failure);}}
 @Override public void onCreate(Bundle state){super.onCreate(state);try{nonce=UUID.fromString(getIntent().getStringExtra("fixture")).toString();}catch(Exception invalid){finish();return;}
  getSharedPreferences("typing-host",0).edit().putString("fixture",nonce).commit();
  LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(24,120,24,24);TextView title=new TextView(this);title.setText("灵鹤合成触控验收");title.setTextSize(22);root.addView(title);
  field=new EditText(this){@Override protected void onSelectionChanged(int start,int end){super.onSelectionChanged(start,end);report();}};field.setTextSize(24);field.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_MULTI_LINE);field.setImeOptions((getIntent().getBooleanExtra("learning",false)?0:EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)|EditorInfo.IME_ACTION_NONE|EditorInfo.IME_FLAG_NO_ENTER_ACTION);field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(256)});root.addView(field,new LinearLayout.LayoutParams(-1,400));setContentView(root);field.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int st,int count,int after){}public void onTextChanged(CharSequence s,int st,int before,int count){report();}public void afterTextChanged(Editable e){report();}});field.requestFocus();report();field.postDelayed(()->((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(field,InputMethodManager.SHOW_IMPLICIT),200);
 }
}
