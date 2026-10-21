package live.linghe.privateinput;
import java.io.IOException;import java.math.BigInteger;
/** Durable group identity barrier. Epoch rotation retains one group's data; group replacement needs departure reset. */
final class RecentLearningScope {
 static final String[] PERSONAL_FILES={"recent-learning-v2.json","recent-learning-policy-v2.json","recent-learning-receipts-v1.json"};
 final String group,binding;final BigInteger epoch,revision;
 RecentLearningScope(String binding)throws Exception{String[] parts=binding.split("/",-1);RecentLearning.require(parts.length==3,"Invalid recent binding");RecentLearningWire.uuid(parts[0]);for(int i=1;i<3;i++)RecentLearning.require(parts[i].matches("[1-9][0-9]{0,19}")&&new BigInteger(parts[i]).compareTo(RecentLearning.MAX_VERSION)<=0,"Invalid recent epoch");group=parts[0].toUpperCase(java.util.Locale.ROOT);epoch=new BigInteger(parts[1]);revision=new BigInteger(parts[2]);this.binding=group+"/"+epoch+"/"+revision;}
 void validateReplacement(RecentLearningScope next,int oldDay,int nextDay)throws IOException{RecentLearning.require(group.equals(next.group),"Recent group changed without departure reset");RecentLearning.require(nextDay>=oldDay,"Recent reference day rollback");}
}
