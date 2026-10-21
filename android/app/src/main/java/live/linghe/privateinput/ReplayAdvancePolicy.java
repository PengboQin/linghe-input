package live.linghe.privateinput;
import java.math.BigInteger;
/** Priority may never evict an unseen positive sequence from the common,
 * cross-domain 64-bit sender window. Unknown windows use ordered full pulls. */
final class ReplayAdvancePolicy {
 static boolean permits(BigInteger high,long bitmap,BigInteger sequence){
  if(high==null||high.signum()<=0||sequence==null||sequence.signum()<=0||high.bitLength()>64||sequence.bitLength()>64||(bitmap&1L)==0)return false;
  BigInteger delta=sequence.subtract(high);
  if(delta.signum()<=0)return delta.compareTo(BigInteger.valueOf(-63))>=0;
  if(delta.compareTo(BigInteger.valueOf(64))>0)return false;
  int advance=delta.intValue();
  for(int offset=64-advance;offset<64;offset++)if(high.subtract(BigInteger.valueOf(offset)).signum()>0&&(bitmap&(1L<<offset))==0)return false;
  return true;
 }
}
