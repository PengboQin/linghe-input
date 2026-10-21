package live.linghe.privateinput;
import java.io.*;
import org.json.*;

/** Separate plaintext archive request namespace; never sends archive text to E2EE relay RPC. */
final class ActivityArchiveWire {
  static JSONObject envelope(JSONObject identity,String group,int operation,JSONObject body,long issuedAt)throws Exception {
    byte[] payload=SyncCrypto.bytes(LosslessJson.canonical(body));
    SyncCrypto.require(payload.length<=524288&&operation>0&&operation<=255);
    JSONObject result=new JSONObject().put("version",1).put("group",SyncCrypto.id(group))
      .put("sender",SyncCrypto.id(identity.getString("device"))).put("nonce",SyncCrypto.id())
      .put("issuedAt",issuedAt).put("operation",operation).put("body",SyncCrypto.b64(payload));
    ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(bytes);
    out.write(SyncCrypto.bytes("PrivateInput/activity-request/v1\0"));out.writeByte(1);
    out.write(SyncCrypto.uuid(result.getString("group")));out.write(SyncCrypto.uuid(result.getString("sender")));
    out.write(SyncCrypto.uuid(result.getString("nonce")));out.writeLong(issuedAt);out.writeByte(operation);out.write(SyncCrypto.sha(payload));
    result.put("signature",SyncCrypto.b64(SyncCrypto.sign(bytes.toByteArray(),SyncCrypto.privateKey("Ed25519",identity.getString("signing")))));
    return result;
  }
  private ActivityArchiveWire(){}
}
