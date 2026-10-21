package live.linghe.privateinput;
import java.io.*;
import java.util.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.*;
import javax.crypto.*;
import javax.crypto.spec.*;
import org.json.*;
/** Apple protocol v1 canonical bytes. No Android UI, network or plaintext logging. */
final class SyncCrypto {
  private static final Provider PROVIDER=new org.bouncycastle.jce.provider.BouncyCastleProvider();
  static final java.nio.charset.Charset UTF8=StandardCharsets.UTF_8;
  static byte[] bytes(String s){
    return s.getBytes(UTF8);
  }
  static String utf8(byte[] b)throws java.nio.charset.CharacterCodingException{
    return UTF8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(b)).toString();
  }
  static String b64(byte[] b){
    return Base64.getEncoder().encodeToString(b);
  }
  static byte[] data(JSONObject j,String key)throws Exception{
    return Base64.getDecoder().decode(j.getString(key));
  }
  static byte[] concat(byte[]... arrays)throws IOException{
    ByteArrayOutputStream out=new ByteArrayOutputStream();
    for(byte[] a:arrays)out.write(a);
    return out.toByteArray();
  }
  static String id(){
    return UUID.randomUUID().toString().toUpperCase(Locale.ROOT);
  }
  static String id(String value){
    return UUID.fromString(value).toString().toUpperCase(Locale.ROOT);
  }
  static byte[] uuid(String value)throws IOException{
    UUID u=UUID.fromString(value);
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.writeLong(u.getMostSignificantBits());
    d.writeLong(u.getLeastSignificantBits());
    return b.toByteArray();
  }
  static BigInteger u(JSONObject j,String key)throws Exception{
    return LosslessJson.unsigned(j.get(key));
  }
  static void number(DataOutputStream d,JSONObject j,String key)throws Exception{
    d.writeLong(u(j,key).longValue());
  }
  static byte[] sha(byte[] b)throws Exception{
    return MessageDigest.getInstance("SHA-256").digest(b);
  }
  static void require(boolean valid)throws IOException{
    if(!valid)throw new IOException("同步资料校验失败");
  }
  static byte[] random(int count){
    byte[] b=new byte[count];
    new SecureRandom().nextBytes(b);
    return b;
  }
  static KeyPair generate(String algorithm)throws Exception{
    return KeyPairGenerator.getInstance(algorithm,PROVIDER).generateKeyPair();
  }
  static byte[] raw(PublicKey key){
    byte[] b=key.getEncoded();
    return Arrays.copyOfRange(b,b.length-32,b.length);
  }
  static PublicKey publicKey(String alg,byte[] raw)throws Exception{
    require(raw.length==32);
    byte[] prefix=hex(alg.equals("Ed25519")?"302a300506032b6570032100":"302a300506032b656e032100");
    return KeyFactory.getInstance(alg,PROVIDER).generatePublic(new X509EncodedKeySpec(concat(prefix,raw)));
  }
  static PrivateKey privateKey(String alg,String encoded)throws Exception{
    return KeyFactory.getInstance(alg,PROVIDER).generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(encoded)));
  }
  static byte[] hex(String value){
    byte[] b=new byte[value.length()/2];
    for(int i=0;i<b.length;i++)b[i]=(byte)Integer.parseInt(value.substring(i*2,i*2+2),16);
    return b;
  }
  static byte[] sign(byte[] bytes,PrivateKey key)throws Exception{
    Signature s=Signature.getInstance("Ed25519",PROVIDER);
    s.initSign(key);
    s.update(bytes);
    return s.sign();
  }
  static void verify(byte[] bytes,byte[] signature,byte[] publicKey)throws Exception{
    require(signature.length==64);
    Signature s=Signature.getInstance("Ed25519",PROVIDER);
    s.initVerify(publicKey("Ed25519",publicKey));
    s.update(bytes);
    require(s.verify(signature));
  }
  static byte[] shared(PrivateKey own,byte[] peer)throws Exception{
    KeyAgreement k=KeyAgreement.getInstance("X25519",PROVIDER);
    k.init(own);
    k.doPhase(publicKey("X25519",peer),true);
    byte[] result=k.generateSecret();
    require(!Arrays.equals(result,new byte[32]));
    return result;
  }
  static byte[] hkdf(byte[] secret,byte[] salt,byte[] info)throws Exception{
    Mac mac=Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(salt,"HmacSHA256"));
    byte[] prk=mac.doFinal(secret);
    mac.init(new SecretKeySpec(prk,"HmacSHA256"));
    return mac.doFinal(concat(info,new byte[]{
      1
    }
    ));
  }
  static byte[] chacha(boolean encrypt,byte[] key,byte[] nonce,byte[] aad,byte[] input)throws Exception{
    Cipher c;
    try{
      c=Cipher.getInstance("ChaCha20-Poly1305",PROVIDER);
    }
    catch(GeneralSecurityException absent){
      c=Cipher.getInstance("ChaCha20/Poly1305/NoPadding",PROVIDER);
    }
    c.init(encrypt?Cipher.ENCRYPT_MODE:Cipher.DECRYPT_MODE,new SecretKeySpec(key,"ChaCha20"),new IvParameterSpec(nonce));
    c.updateAAD(aad);
    return c.doFinal(input);
  }
  static JSONObject member(JSONObject identity)throws Exception{
    return new JSONObject().put("device",identity.getString("device")).put("signingPublic",identity.getString("signingPublic")).put("exchangePublic",identity.getString("exchangePublic")).put("permissions",3);
  }
  static JSONObject identity()throws Exception{
    KeyPair sign=generate("Ed25519"),exchange=generate("X25519"),owner=generate("Ed25519");
    return new JSONObject().put("device",id()).put("signing",b64(sign.getPrivate().getEncoded())).put("signingPublic",b64(raw(sign.getPublic()))).put("exchange",b64(exchange.getPrivate().getEncoded())).put("exchangePublic",b64(raw(exchange.getPublic()))).put("ownerID",id()).put("owner",b64(owner.getPrivate().getEncoded())).put("ownerPublic",b64(raw(owner.getPublic())));
  }
  static byte[] canonicalPair(JSONObject j)throws Exception{
    JSONObject m=j.getJSONObject("member");
    require(j.getInt("version")==1&&m.getInt("permissions")==3&&data(m,"signingPublic").length==32&&data(m,"exchangePublic").length==32&&data(j,"challenge").length==32);
    time(j,600);
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.write(bytes("PrivateInput/pair-request/v1\0"));
    d.writeByte(1);
    d.write(uuid(j.getString("session")));
    d.write(uuid(m.getString("device")));
    d.write(data(m,"signingPublic"));
    d.write(data(m,"exchangePublic"));
    d.write(data(j,"challenge"));
    number(d,j,"issuedAt");
    number(d,j,"expiresAt");
    return b.toByteArray();
  }
  static JSONObject pair(JSONObject identity,long now)throws Exception{
    JSONObject j=new JSONObject().put("version",1).put("session",id()).put("member",member(identity)).put("challenge",b64(random(32))).put("issuedAt",now).put("expiresAt",now+600);
    j.put("signature",b64(sign(canonicalPair(j),privateKey("Ed25519",identity.getString("signing")))));
    return j;
  }
  static void time(JSONObject j,long maximum)throws Exception{
    BigInteger issued=u(j,"issuedAt"),expires=u(j,"expiresAt");
    require(expires.compareTo(issued)>0&&expires.subtract(issued).compareTo(BigInteger.valueOf(maximum))<=0);
  }
  static void live(JSONObject j,long now)throws Exception{
    require(u(j,"expiresAt").compareTo(BigInteger.valueOf(now))>0&&u(j,"issuedAt").compareTo(BigInteger.valueOf(now+300))<=0);
  }
  static byte[] membership(JSONObject j)throws Exception{
    JSONArray members=j.getJSONArray("members");
    require((j.getInt("version")==1||j.getInt("version")==2)&&u(j,"revision").signum()>0&&u(j,"revision").equals(u(j,"epoch"))&&data(j,"ownerPublic").length==32&&members.length()>0&&members.length()<=64);
    ArrayList<JSONObject> sorted=new ArrayList<>();
    Set<String> ids=new HashSet<>(),keys=new HashSet<>(),exchanges=new HashSet<>();
    for(int i=0;i<members.length();i++){
      JSONObject m=members.getJSONObject(i);
      require(ids.add(id(m.getString("device")))&&keys.add(m.getString("signingPublic"))&&exchanges.add(m.getString("exchangePublic"))&&data(m,"signingPublic").length==32&&data(m,"exchangePublic").length==32&&m.getInt("permissions")>0&&m.getInt("permissions")<=3);
      sorted.add(m);
    }
    sorted.sort((a,c)->a.optString("device").toUpperCase(Locale.ROOT).compareTo(c.optString("device").toUpperCase(Locale.ROOT)));
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.write(bytes("PrivateInput/membership/v1\0"));
    d.writeByte(j.getInt("version"));
    d.write(uuid(j.getString("group")));
    d.write(uuid(j.getString("ownerID")));
    d.write(data(j,"ownerPublic"));
    number(d,j,"revision");
    number(d,j,"epoch");
    d.writeByte(members.length());
    for(JSONObject m:sorted){
      d.write(uuid(m.getString("device")));
      d.write(data(m,"signingPublic"));
      d.write(data(m,"exchangePublic"));
      d.writeByte(m.getInt("permissions"));
    }
    if(j.getInt("version")==2){d.write(uuid(j.getString("issuer")));require(data(j,"parent").length==32);d.write(data(j,"parent"));}
    else require(!j.has("issuer")&&!j.has("parent")&&!j.has("history"));
    return b.toByteArray();
  }
  static JSONObject find(JSONObject membership,String id)throws Exception{
    JSONArray array=membership.getJSONArray("members");
    for(int i=0;i<array.length();i++)if(id(array.getJSONObject(i).getString("device")).equals(id(id)))return array.getJSONObject(i);
    throw new IOException("当前设备不在设备组内");
  }
  static byte[] authorizationPublic(JSONObject m)throws Exception{
    if(m.getInt("version")==1)return data(m,"ownerPublic");
    JSONArray proof=m.getJSONArray("history");require(proof.length()>0&&proof.length()<=1024);
    JSONObject signer=find(proof.getJSONObject(proof.length()-1),m.getString("issuer"));require(signer.getInt("permissions")==3);
    return data(signer,"signingPublic");
  }
  static PrivateKey authorizationKey(JSONObject m,JSONObject identity)throws Exception{
    if(m.getInt("version")==1){require(id(m.getString("ownerID")).equals(id(identity.getString("ownerID"))));return privateKey("Ed25519",identity.getString("owner"));}
    require(id(m.getString("issuer")).equals(id(identity.getString("device")))&&Arrays.equals(authorizationPublic(m),data(identity,"signingPublic")));
    return privateKey("Ed25519",identity.getString("signing"));
  }
  static JSONObject successor(JSONObject current,JSONArray members,JSONObject identity)throws Exception{
    require(find(current,identity.getString("device")).getInt("permissions")==3);
    JSONObject predecessor=new JSONObject(current.toString());predecessor.remove("history");
    JSONArray history=current.has("history")?new JSONArray(current.getJSONArray("history").toString()):new JSONArray();history.put(predecessor);require(history.length()<=1024);
    BigInteger revision=u(current,"revision").add(BigInteger.ONE);require(revision.compareTo(LosslessJson.UINT64_MAX)<=0);
    JSONObject next=new JSONObject(current.toString()).put("version",2).put("revision",revision).put("epoch",revision).put("members",members).put("issuer",identity.getString("device")).put("parent",b64(sha(membership(current)))).put("history",history);
    next.put("signature",b64(sign(membership(next),privateKey("Ed25519",identity.getString("signing")))));
    verifyMembership(next,anchor(current),current);return next;
  }
  static void verifyMembership(JSONObject m,JSONObject anchor,JSONObject old)throws Exception{
    JSONArray history=m.optJSONArray("history");if(history==null)history=new JSONArray();require(history.length()<=1024&&((m.getInt("version")==2)==(history.length()>0)));
    JSONObject previous=null;byte[] previousBytes=null,retained=null;
    for(int i=0;i<=history.length();i++){
      JSONObject item=i==history.length()?m:history.getJSONObject(i);if(i<history.length())require(!item.has("history"));
      require(id(item.getString("group")).equals(id(anchor.getString("group")))&&id(item.getString("ownerID")).equals(id(anchor.getString("ownerID")))&&item.getString("ownerPublic").equals(anchor.getString("ownerPublic")));
      byte[] canonical=membership(item),publicKey;
      if(previous==null){require(item.getInt("version")==1);publicKey=data(anchor,"ownerPublic");}
      else{
        require(item.getInt("version")==2&&u(item,"revision").equals(u(previous,"revision").add(BigInteger.ONE))&&Arrays.equals(data(item,"parent"),sha(previousBytes)));
        JSONObject signer=find(previous,item.getString("issuer"));require(signer.getInt("permissions")==3);publicKey=data(signer,"signingPublic");
      }
      verify(canonical,data(item,"signature"),publicKey);
      if(old!=null&&u(item,"revision").equals(u(old,"revision")))retained=sha(canonical);
      previous=item;previousBytes=canonical;
    }
    if(old!=null){int c=u(m,"revision").compareTo(u(old,"revision"));require(c>=0);if(m.getInt("version")==2)require(Arrays.equals(retained,sha(membership(old))));else if(c==0)require(Arrays.equals(membership(m),membership(old)));}
  }
  static JSONObject anchor(JSONObject m)throws Exception{
    return new JSONObject().put("group",m.getString("group")).put("ownerID",m.getString("ownerID")).put("ownerPublic",m.getString("ownerPublic"));
  }
  static byte[] wrappedHeader(JSONObject j)throws Exception{
    JSONObject m=j.getJSONObject("membership"),recipient=find(m,j.getString("recipient"));
    int purpose=j.getInt("purpose");
    byte[] context=data(j,"context");
    require(j.getInt("version")==1&&(purpose==1||purpose==2)&&context.length==32&&data(j,"ephemeralPublic").length==32&&((purpose==2)==Arrays.equals(context,new byte[32])));
    time(j,purpose==1?600:2592000);
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.write(bytes("PrivateInput/wrapped-group-key/v1\0"));
    d.writeByte(1);
    d.writeByte(purpose);
    d.write(uuid(j.getString("recipient")));
    d.write(data(recipient,"exchangePublic"));
    d.write(data(j,"ephemeralPublic"));
    d.write(context);
    d.write(sha(membership(m)));
    number(d,j,"issuedAt");
    number(d,j,"expiresAt");
    return b.toByteArray();
  }
  static byte[] openKey(JSONObject j,JSONObject identity,JSONObject anchor,JSONObject previous,byte[] context,long now)throws Exception{
    live(j,now);
    require(id(j.getString("recipient")).equals(id(identity.getString("device")))&&Arrays.equals(data(j,"context"),context));
    JSONObject m=j.getJSONObject("membership");
    verifyMembership(m,anchor,previous);
    JSONObject member=find(m,identity.getString("device"));
    require(member.getString("signingPublic").equals(identity.getString("signingPublic"))&&member.getString("exchangePublic").equals(identity.getString("exchangePublic")));
    byte[] header=wrappedHeader(j),box=data(j,"sealedKey");
    require(box.length==60);
    verify(concat(header,box),data(j,"signature"),authorizationPublic(m));
    byte[] secret=shared(privateKey("X25519",identity.getString("exchange")),data(j,"ephemeralPublic"));
    byte[] key=hkdf(secret,sha(header),bytes("PrivateInput/wrapping-key/v1\0"));
    byte[] result=chacha(false,key,Arrays.copyOf(box,12),header,Arrays.copyOfRange(box,12,box.length));
    require(result.length==32);
    return result;
  }
  static byte[] eventHeader(JSONObject j)throws Exception{
    int domain=j.getInt("domain");
    require(j.getInt("version")==1&&(domain==1||domain==2)&&u(j,"sequence").signum()>0&&u(j,"epoch").signum()>0);
    time(j,domain==1?604800:600);
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.write(bytes("PrivateInput/event/v1\0"));
    d.writeByte(1);
    for(String field:new String[]{
      "group","sender","event"
    }
    )d.write(uuid(j.getString(field)));
    number(d,j,"epoch");
    number(d,j,"sequence");
    d.writeByte(domain);
    number(d,j,"issuedAt");
    number(d,j,"expiresAt");
    return b.toByteArray();
  }
  static byte[] eventKey(JSONObject j,JSONObject membership,byte[] key)throws Exception{
    JSONObject member=find(membership,j.getString("sender"));
    require((member.getInt("permissions")&j.getInt("domain"))!=0&&id(j.getString("group")).equals(id(membership.getString("group")))&&u(j,"epoch").equals(u(membership,"epoch")));
    byte[] salt=concat(uuid(j.getString("group")),be(u(j,"epoch")));
    byte[] info=concat(bytes("PrivateInput/sender-domain-key/v1\0"),uuid(j.getString("sender")),data(member,"signingPublic"),new byte[]{
      (byte)j.getInt("domain")
    }
    );
    return hkdf(key,salt,info);
  }
  static byte[] be(BigInteger number)throws IOException{
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    new DataOutputStream(b).writeLong(number.longValue());
    return b.toByteArray();
  }
  static byte[] nonce(JSONObject j)throws Exception{
    return concat(new byte[4],be(u(j,"sequence")));
  }
  static JSONObject seal(byte[] payload,int domain,JSONObject state,long now)throws Exception{return seal(payload,domain,state,now,id());}
  static JSONObject seal(byte[] payload,int domain,JSONObject state,long now,String event)throws Exception{return seal(payload,domain,state,now,event,now+(domain==1?604800:600));}
  static JSONObject seal(byte[] payload,int domain,JSONObject state,long now,String event,long expires)throws Exception{
    JSONObject identity=state.getJSONObject("identity"),m=state.getJSONObject("membership");
    JSONObject j=new JSONObject().put("version",1).put("group",m.getString("group")).put("sender",identity.getString("device")).put("event",id(event)).put("epoch",m.get("epoch")).put("sequence",state.get("sequence")).put("domain",domain).put("issuedAt",now).put("expiresAt",expires);
    byte[] header=eventHeader(j);
    byte[] box=chacha(true,eventKey(j,m,data(state,"groupKey")),nonce(j),header,payload);
    j.put("ciphertext",b64(box));
    j.put("signature",b64(sign(concat(header,box),privateKey("Ed25519",identity.getString("signing")))));
    return j;
  }
  static byte[] open(JSONObject j,JSONObject m,byte[] key,long now)throws Exception{
    live(j,now);
    byte[] header=eventHeader(j),box=data(j,"ciphertext");
    require(box.length>=16&&box.length<=(j.getInt("domain")==1?2097152:65536)+16);
    verify(concat(header,box),data(j,"signature"),data(find(m,j.getString("sender")),"signingPublic"));
    return chacha(false,eventKey(j,m,key),nonce(j),header,box);
  }
  static JSONObject request(JSONObject identity,String group,int operation,byte[] body,boolean owner,long now)throws Exception{
    require(body.length<=65536);
    String sender=identity.getString(owner?"ownerID":"device");
    JSONObject j=new JSONObject().put("version",1).put("group",group).put("sender",sender).put("nonce",id()).put("issuedAt",now).put("operation",operation).put("body",b64(body));
    ByteArrayOutputStream b=new ByteArrayOutputStream();
    DataOutputStream d=new DataOutputStream(b);
    d.write(bytes("PrivateInput/relay-request/v1\0"));
    d.writeByte(1);
    d.write(uuid(group));
    d.write(uuid(sender));
    d.write(uuid(j.getString("nonce")));
    number(d,j,"issuedAt");
    d.writeByte(operation);
    d.write(sha(body));
    j.put("signature",b64(sign(b.toByteArray(),privateKey("Ed25519",identity.getString(owner?"owner":"signing")))));
    return j;
  }
  static JSONObject newMembership(JSONObject identity)throws Exception {
    JSONObject m=new JSONObject().put("version",1).put("group",id()).put("ownerID",identity.getString("ownerID")).put("ownerPublic",identity.getString("ownerPublic")).put("revision",1).put("epoch",1).put("members",new JSONArray().put(member(identity)));
    m.put("signature",b64(sign(membership(m),privateKey("Ed25519",identity.getString("owner")))));
    return m;
  }
  static JSONObject wrap(JSONObject m,String recipient,byte[] groupKey,byte[] context,JSONObject identity,long now,long expires)throws Exception {
    KeyPair ephemeral=generate("X25519");
    JSONObject j=new JSONObject().put("version",1).put("purpose",Arrays.equals(context,new byte[32])?2:1).put("recipient",recipient).put("ephemeralPublic",b64(raw(ephemeral.getPublic()))).put("context",b64(context)).put("membership",m).put("issuedAt",now).put("expiresAt",expires);
    byte[] header=wrappedHeader(j),secret=shared(ephemeral.getPrivate(),data(find(m,recipient),"exchangePublic")),key=hkdf(secret,sha(header),bytes("PrivateInput/wrapping-key/v1\0")),nonce=random(12),box=concat(nonce,chacha(true,key,nonce,header,groupKey));
    j.put("sealedKey",b64(box)).put("signature",b64(sign(concat(header,box),authorizationKey(m,identity))));
    return j;
  }
  static String encodeQR(JSONObject qr)throws Exception{
    byte[] key=sha(bytes("LingheInput/qr-envelope/v2/public-reader-key")),nonce=random(12);Cipher c=Cipher.getInstance("AES/GCM/NoPadding",PROVIDER);
    c.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new javax.crypto.spec.GCMParameterSpec(128,nonce));c.updateAAD(bytes("LingheInput/qr-envelope/v2"));
    return "v2:"+b64(concat(nonce,c.doFinal(bytes(qr.toString()))));
  }
  static JSONObject decodeQRQuery(String raw)throws Exception{return decodeQR(java.net.URLDecoder.decode(raw.replace("+","%2B"),"UTF-8"));}
  static JSONObject decodeQR(String text)throws Exception{
    if(!text.startsWith("v2:"))return LosslessJson.object(utf8(Base64.getDecoder().decode(text)),8192);
    byte[] box=Base64.getDecoder().decode(text.substring(3));require(box.length>=28&&box.length<=8192);Cipher c=Cipher.getInstance("AES/GCM/NoPadding",PROVIDER);
    c.init(Cipher.DECRYPT_MODE,new SecretKeySpec(sha(bytes("LingheInput/qr-envelope/v2/public-reader-key")),"AES"),new javax.crypto.spec.GCMParameterSpec(128,Arrays.copyOf(box,12)));c.updateAAD(bytes("LingheInput/qr-envelope/v2"));
    return LosslessJson.object(utf8(c.doFinal(Arrays.copyOfRange(box,12,box.length))),8192);
  }

}
