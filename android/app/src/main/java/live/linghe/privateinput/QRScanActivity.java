package live.linghe.privateinput;
import android.app.*;
import android.os.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.hardware.Camera;
import android.view.*;
import android.widget.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
/** Frames stay in memory; camera exists only while the explicit scanner is visible. */
@SuppressWarnings("deprecation") public final class QRScanActivity extends Activity implements SurfaceHolder.Callback {
  private Camera camera;
  private SurfaceView preview;
  private final AtomicBoolean decoding=new AtomicBoolean();
  private volatile boolean active,found;
  private final java.util.concurrent.ExecutorService decoder=java.util.concurrent.Executors.newSingleThreadExecutor();
  @Override public void onCreate(Bundle saved){
    super.onCreate(saved);
    LinearLayout root=new LinearLayout(this);
    root.setOrientation(1);
    root.setPadding(0,Ui.dp(this,40),0,Ui.dp(this,24));
    root.setBackgroundColor(Ui.page(this));
    Button back=new Button(this);
    back.setText("返回");
    back.setOnClickListener(v->finish());
    root.addView(back);
    TextView title=new TextView(this);
    title.setText("扫描灵鹤输入法的限时二维码");
    title.setTextColor(Ui.text(this));
    title.setGravity(Gravity.CENTER);
    root.addView(title,new LinearLayout.LayoutParams(-1,Ui.dp(this,50)));
    preview=new SurfaceView(this);
    preview.getHolder().addCallback(this);
    root.addView(preview,new LinearLayout.LayoutParams(-1,0,1));
    setContentView(root);
  }
  @Override protected void onResume(){
    super.onResume();
    active=true;
    if(checkSelfPermission(android.Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{
      android.Manifest.permission.CAMERA
    }
    ,1);
    else start();
  }
  @Override protected void onPause(){
    active=false;
    close();
    super.onPause();
  }
  @Override public void onRequestPermissionsResult(int r,String[] p,int[] results){
    super.onRequestPermissionsResult(r,p,results);
    if(r==1&&results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED)start();
    else{
      Toast.makeText(this,"也可以使用六位接入码",Toast.LENGTH_LONG).show();
      finish();
    }
  }
  public void surfaceCreated(SurfaceHolder h){
    start();
  }
  public void surfaceChanged(SurfaceHolder h,int f,int w,int height){
  }
  public void surfaceDestroyed(SurfaceHolder h){
    close();
  }
  private void start(){
    if(!active||found||camera!=null||!preview.getHolder().getSurface().isValid()||checkSelfPermission(android.Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)return;
    try{
      camera=Camera.open();
      Camera.Parameters p=camera.getParameters();
      Camera.Size best=null;
      for(Camera.Size s:p.getSupportedPreviewSizes())if(s.width<=1280&&(best==null||s.width>best.width))best=s;
      if(best!=null)p.setPreviewSize(best.width,best.height);
      if(p.getSupportedFocusModes().contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE))p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
      camera.setParameters(p);
      camera.setDisplayOrientation(90);
      camera.setPreviewDisplay(preview.getHolder());
      camera.setPreviewCallback((data,cam)->{
        if(!active||found||!decoding.compareAndSet(false,true))return;Camera.Size size=cam.getParameters().getPreviewSize();byte[] frame=Arrays.copyOf(data,size.width*size.height);decoder.execute(()->{
          String result=null;try{
            Map<DecodeHintType,Object> hints=new EnumMap<>(DecodeHintType.class);hints.put(DecodeHintType.POSSIBLE_FORMATS,Collections.singletonList(BarcodeFormat.QR_CODE));MultiFormatReader reader=new MultiFormatReader();reader.setHints(hints);LuminanceSource source=new PlanarYUVLuminanceSource(frame,size.width,size.height,0,0,size.width,size.height,false);result=reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(source))).getText();
          }
          catch(Exception ignored){
          }
          finally{
            decoding.set(false);
          }
          String link=result;if(link!=null&&link.startsWith("privateinput://pair?"))runOnUiThread(()->{
            if(active&&!found){
              found=true;close();setResult(RESULT_OK,new Intent().putExtra("qr",link));finish();
            }
          }
          );
        }
        );
      }
      );
      camera.startPreview();
    }
    catch(Exception error){
      close();
      Toast.makeText(this,"无法打开相机，请使用六位接入码",Toast.LENGTH_LONG).show();
      finish();
    }
  }
  @Override protected void onDestroy(){
    decoder.shutdownNow();
    super.onDestroy();
  }
  private void close(){
    if(camera!=null){
      camera.setPreviewCallback(null);
      camera.stopPreview();
      camera.release();
      camera=null;
    }
  }
}
