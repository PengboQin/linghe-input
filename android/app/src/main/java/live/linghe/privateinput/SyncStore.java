package live.linghe.privateinput;
import android.content.Context;
import android.util.AtomicFile;
import android.security.keystore.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import java.io.*;
import java.security.KeyStore;
import org.json.*;
/** One authenticated, atomic app-private state. Keystore key is not exportable. */
final class SyncStore {
  private final File directory;
  private final AtomicFile file;
  private final String alias;
  SyncStore(Context context){this(context,"live.linghe.privateinput.sync.storage.v1");}
  SyncStore(Context context,String storageAlias){
    directory=new File(context.getFilesDir(),"Sync");
    file=new AtomicFile(new File(directory,"state-v1.enc"));
    alias=storageAlias;
  }
  private javax.crypto.SecretKey key(boolean create)throws Exception{
    KeyStore ks=KeyStore.getInstance("AndroidKeyStore");
    ks.load(null);
    if(!ks.containsAlias(alias)){
      if(!create)throw new IOException("同步密钥暂不可用，原文件已保留");
      KeyGenerator g=KeyGenerator.getInstance("AES","AndroidKeyStore");
      g.init(new KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build());
      g.generateKey();
    }
    return(javax.crypto.SecretKey)ks.getKey(alias,null);
  }
  JSONObject load()throws Exception{
    return AppFiles.locked(directory,"sync.lock",()->{
      String wire=AppFiles.readOptional(file,8*1024*1024);if(wire==null)return new JSONObject().put("version",1).put("sequence",0).put("ledger",new JSONObject()).put("inbox",new JSONArray()).put("outbox",new JSONArray());JSONObject box=LosslessJson.object(wire,8*1024*1024);SyncCrypto.require(box.getInt("version")==1&&SyncCrypto.data(box,"nonce").length==12);Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.DECRYPT_MODE,key(false),new GCMParameterSpec(128,SyncCrypto.data(box,"nonce")));c.updateAAD(SyncCrypto.bytes("PrivateInput/android-sync-store/v1\0"));JSONObject result=LosslessJson.object(SyncCrypto.utf8(c.doFinal(SyncCrypto.data(box,"ciphertext"))),6*1024*1024);SyncCrypto.require(result.getInt("version")==1);SyncCrypto.u(result,"sequence");return result;
    }
    );
  }
  void resetForDeparture()throws Exception{
    AppFiles.locked(directory,"sync.lock",()->{file.delete();KeyStore ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);ks.deleteEntry(alias);return null;});
  }
  void save(JSONObject state)throws Exception{
    AppFiles.locked(directory,"sync.lock",()->{
      byte[] clear=LosslessJson.canonical(state).getBytes(SyncCrypto.UTF8);SyncCrypto.require(clear.length<=6*1024*1024);Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,key(true));c.updateAAD(SyncCrypto.bytes("PrivateInput/android-sync-store/v1\0"));JSONObject wire=new JSONObject().put("version",1).put("nonce",SyncCrypto.b64(c.getIV())).put("ciphertext",SyncCrypto.b64(c.doFinal(clear)));AppFiles.write(file,wire.toString(),8*1024*1024);return null;
    }
    );
  }
}
