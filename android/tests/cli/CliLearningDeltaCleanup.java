package live.linghe.privateinput;
import java.security.KeyStore;
import java.util.*;
/** One-off recovery for this newly introduced synthetic fixture namespace.
 * Never emits other aliases, never reads key material, never creates a key. */
public final class CliLearningDeltaCleanup {
 public static void main(String[]args)throws Exception{
  if(args.length!=2)throw new IllegalArgumentException("bounded test creation window required");long first=Long.parseLong(args[0]),last=Long.parseLong(args[1]);if(first<0||last<first||last-first>600000)throw new IllegalArgumentException("invalid bounded test window");
  System.out.println("CLEANUP_STARTED");KeyStore keys=KeyStore.getInstance("AndroidKeyStore");keys.load(null);List<String> own=new ArrayList<>();Enumeration<String> aliases=keys.aliases();while(aliases.hasMoreElements()){String alias=aliases.nextElement();if(alias.matches("live\\.linghe\\.fixture\\.delta\\.[0-9a-f]{16}"))own.add(alias);}
  int removed=0;for(String alias:own){Date created=keys.getCreationDate(alias);if(created==null||created.getTime()<first||created.getTime()>last)throw new IllegalStateException("Fixture alias outside this run; preserved");keys.deleteEntry(alias);if(keys.containsAlias(alias))throw new IllegalStateException("Fixture alias remains");removed++;}
  System.out.println("CLEANUP fixtureAliasesFound="+own.size()+" fixtureAliasesRemoved="+removed+" otherKeysRead=false keysCreated=false");
 }
}
