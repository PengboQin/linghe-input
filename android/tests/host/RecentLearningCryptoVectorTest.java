package live.linghe.privateinput;
import java.util.*;import java.io.*;import java.math.BigInteger;import java.nio.file.*;
public final class RecentLearningCryptoVectorTest {
 static int checks;static void ok(boolean b,String label){checks++;if(!b)throw new AssertionError(label);}
 interface Work{void run()throws Exception;}static void rejects(Work work,String label)throws Exception{boolean bad=false;try{work.run();}catch(Exception e){bad=true;}ok(bad,label);}
 static byte[] b(Properties p,String key){return Base64.getDecoder().decode(p.getProperty(key));}
 public static void main(String[] args)throws Exception{
  Properties p=new Properties();try(InputStream in=Files.newInputStream(Paths.get(args[0]))){p.load(in);}String group=p.getProperty("group"),sender=p.getProperty("sender"),event=p.getProperty("event");BigInteger epoch=new BigInteger(p.getProperty("epoch")),issued=new BigInteger(p.getProperty("issuedAt")),expires=new BigInteger(p.getProperty("expiresAt"));
  byte[] header=RecentLearningWire.header(group,sender,event,epoch,issued,expires),sealed=b(p,"sealed");ok(Arrays.equals(header,b(p,"header")),"Swift/Java envelope canonical bytes");SyncCrypto.verify(SyncCrypto.concat(header,sealed),b(p,"signature"),b(p,"signingPublic"));ok(true,"Swift Ed25519 envelope verified by Java/BC");
  byte[] key=SyncCrypto.hkdf(b(p,"groupKey"),RecentLearningWire.salt(group,epoch),RecentLearningWire.info(sender,b(p,"signingPublic"))),nonce=Arrays.copyOfRange(sealed,0,12),cipher=Arrays.copyOfRange(sealed,12,sealed.length);byte[] payload=SyncCrypto.chacha(false,key,nonce,header,cipher);ok(Arrays.equals(payload,b(p,"payload")),"Swift HKDF/ChaCha payload actually opened");
  ok(Arrays.equals(SyncCrypto.concat(nonce,SyncCrypto.chacha(true,key,nonce,header,payload)),sealed),"Java reencrypt exact Swift vector");
  byte[] request=RecentLearningWire.request(group,sender,p.getProperty("request.nonce"),new BigInteger(p.getProperty("request.issuedAt")),Integer.parseInt(p.getProperty("request.operation")),b(p,"request.body"));ok(Arrays.equals(request,b(p,"requestCanonical")),"Swift/Java request canonical bytes");SyncCrypto.verify(request,b(p,"request.signature"),b(p,"signingPublic"));ok(true,"Swift request Ed25519 verified");
  byte[] pkcs8=SyncCrypto.concat(SyncCrypto.hex("302e020100300506032b657004220420"),b(p,"signingSeed"));byte[] ownSignature=SyncCrypto.sign(request,SyncCrypto.privateKey("Ed25519",SyncCrypto.b64(pkcs8)));SyncCrypto.verify(request,ownSignature,b(p,"signingPublic"));ok(true,"Java signature from Swift seed verifies with Swift public key");
  byte[] changed=cipher.clone();changed[0]^=1;rejects(()->SyncCrypto.chacha(false,key,nonce,header,changed),"ciphertext tamper rejected");byte[] changedHeader=header.clone();changedHeader[changedHeader.length-1]^=1;rejects(()->SyncCrypto.chacha(false,key,nonce,changedHeader,cipher),"header tamper rejected");byte[] changedKey=key.clone();changedKey[0]^=1;rejects(()->SyncCrypto.chacha(false,changedKey,nonce,header,cipher),"wrong key rejected");rejects(()->SyncCrypto.verify(request,b(p,"signature"),b(p,"signingPublic")),"envelope signature cannot authorize RPC request");
  System.out.println("PASS "+checks+" actual Swift/Android crypto checks");
 }
}
