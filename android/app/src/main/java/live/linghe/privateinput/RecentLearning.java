package live.linghe.privateinput;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.text.Normalizer;
import java.util.*;

/** Cross-platform recency algorithm 1. No wall-clock, Android, disk or network calls. */
final class RecentLearning {
 static final long MAX_COUNT=1_000_000_000L;
 static final int MAX_WORDS=5000,MAX_COMPONENTS=40000;
 static final BigInteger MAX_VERSION=new BigInteger("18446744073709551615");
 static void require(boolean value,String message)throws IOException{if(!value)throw new IOException(message);}
 static String nfc(String value){return Normalizer.normalize(value,Normalizer.Form.NFC);}
 static void unicode(String value)throws IOException{for(int i=0;i<value.length();i++){char c=value.charAt(i);if(Character.isHighSurrogate(c))require(++i<value.length()&&Character.isLowSurrogate(value.charAt(i)),"Invalid Unicode");else require(!Character.isLowSurrogate(c),"Invalid Unicode");}}
 static void name(String value)throws IOException{unicode(value);require(!value.isEmpty()&&value.getBytes(StandardCharsets.UTF_8).length<=128,"Invalid replica");}
 static final class Policy {
  final int referenceDay,windowDays;
  Policy(int day)throws IOException{this(day,90);}
  Policy(int day,int window)throws IOException{require(day>=90&&day<=3000000&&window>=1&&window<=90,"Invalid recency policy");referenceDay=day;windowDays=window;}
  boolean accepts(int day){return day>referenceDay-windowDays&&day<=referenceDay;}
 }
 static final class Clock {
  final double anchorUnixSeconds,anchorUptime;final String bootSession;double lastUptime;boolean trusted=true;
  Clock(double authenticatedSeconds,double uptime,String boot)throws IOException{require(Double.isFinite(authenticatedSeconds)&&authenticatedSeconds>=0&&authenticatedSeconds<=259200000000.0&&Double.isFinite(uptime)&&uptime>=0,"Invalid authenticated clock");name(boot);anchorUnixSeconds=authenticatedSeconds;anchorUptime=lastUptime=uptime;bootSession=boot;}
  Integer day(double wallSeconds,double uptime,String boot){
   if(!trusted||!Double.isFinite(wallSeconds)||!Double.isFinite(uptime)||!bootSession.equals(boot)||uptime<anchorUptime||uptime<lastUptime||uptime-anchorUptime>7*86400){trusted=false;return null;}
   double expected=anchorUnixSeconds+uptime-anchorUptime;
   if(Math.abs(wallSeconds-expected)>86400||expected<0||expected>259200000000.0){trusted=false;return null;}
   lastUptime=uptime;return (int)Math.floor(expected/86400);
  }
 }
 static final class Version implements Comparable<Version>{
  final BigInteger sequence;final String replica;
  Version(BigInteger sequence,String replica)throws IOException{require(sequence.signum()>=0&&sequence.compareTo(MAX_VERSION)<=0&&replica.getBytes(StandardCharsets.UTF_8).length<=128,"Invalid pin version");unicode(replica);this.sequence=sequence;this.replica=nfc(replica);}
  public int compareTo(Version other){int n=sequence.compareTo(other.sequence);return n==0?replica.compareTo(other.replica):n;}
 }
 static final class Entry {
  final String reading,text;final BigInteger generation;final boolean deleted,pinned;final Version pinVersion;
  final Map<String,Long> counts;final Map<Integer,Map<String,Long>> buckets;
  Entry(String reading,String text,BigInteger generation,boolean deleted,Map<String,Long> counts,boolean pinned,Version pinVersion,Map<Integer,Map<String,Long>> buckets)throws IOException{
   this.reading=reading;this.text=text;this.generation=generation;this.deleted=deleted;this.pinned=pinned;this.pinVersion=pinVersion;Map<String,Long> totals=new LinkedHashMap<>();for(Map.Entry<String,Long> c:counts.entrySet()){String key=nfc(c.getKey());require(!totals.containsKey(key),"Duplicate recent replica");totals.put(key,c.getValue());}this.counts=Collections.unmodifiableMap(totals);
   Map<Integer,Map<String,Long>> copy=new TreeMap<>();for(Map.Entry<Integer,Map<String,Long>> b:buckets.entrySet()){Map<String,Long> values=new LinkedHashMap<>();for(Map.Entry<String,Long> c:b.getValue().entrySet()){String key=nfc(c.getKey());require(!values.containsKey(key),"Duplicate recent replica");values.put(key,c.getValue());}copy.put(b.getKey(),Collections.unmodifiableMap(values));}this.buckets=Collections.unmodifiableMap(copy);validate();
  }
  static Entry fresh(String reading,String text)throws IOException{return new Entry(reading.toLowerCase(Locale.ROOT),nfc(text),BigInteger.ZERO,false,Collections.emptyMap(),false,new Version(BigInteger.ZERO,""),Collections.emptyMap());}
  String id(){return nfc(reading+'\u001f'+text);}
  long frequency(){long sum=0;for(long value:counts.values())sum=Math.min(MAX_COUNT,sum+value);return sum;}
  void validate()throws IOException{
   unicode(reading);unicode(text);require(!reading.isEmpty()&&reading.matches("[a-zA-Z ']+")&&reading.getBytes(StandardCharsets.UTF_8).length<=128&&!text.isEmpty()&&text.getBytes(StandardCharsets.UTF_8).length<=1024&&!text.matches("(?s).*[\\u001f\\t\\n\\r\\u0000].*"),"Invalid recent word");
   require(generation.signum()>=0&&generation.compareTo(MAX_VERSION)<=0&&counts.size()<=64&&buckets.size()<=90,"Invalid recent generation or size");
   for(Map.Entry<String,Long> c:counts.entrySet()){name(c.getKey());require(c.getValue()>=0&&c.getValue()<=MAX_COUNT,"Invalid cumulative count");}
   Map<String,Long> sums=new HashMap<>();
   for(Map.Entry<Integer,Map<String,Long>> bucket:buckets.entrySet()){
    require(bucket.getKey()>=0&&bucket.getKey()<=3000000&&!bucket.getValue().isEmpty()&&bucket.getValue().size()<=64,"Invalid day bucket");
    for(Map.Entry<String,Long> c:bucket.getValue().entrySet()){long sum=sums.getOrDefault(c.getKey(),0L),total=counts.getOrDefault(c.getKey(),-1L);require(c.getValue()>0&&c.getValue()<=MAX_COUNT&&sum<=total&&c.getValue()<=total-sum,"Recent counts exceed cumulative");sums.put(c.getKey(),sum+c.getValue());}
   }
  }
  Entry normalized(Policy policy)throws IOException{Map<Integer,Map<String,Long>> days=new TreeMap<>();for(Map.Entry<Integer,Map<String,Long>> b:buckets.entrySet())if(policy.accepts(b.getKey()))days.put(b.getKey(),b.getValue());return new Entry(reading,text,generation,deleted,counts,pinned,pinVersion,days);}
  Entry merge(Entry incoming,Policy policy)throws IOException{
   require(id().equals(incoming.id()),"Mismatched recent identity");Entry left=normalized(policy),right=incoming.normalized(policy);int pin=left.pinVersion.compareTo(right.pinVersion);
   require(pin!=0||left.pinned==right.pinned,"Forked pin version");Entry newestPin=pin<0?right:left;
   if(!generation.equals(incoming.generation)){Entry e=generation.compareTo(incoming.generation)>0?left:right;return new Entry(e.reading,e.text,e.generation,e.deleted,e.counts,newestPin.pinned,newestPin.pinVersion,e.buckets);}
   Map<String,Long> totals=new LinkedHashMap<>(counts);for(Map.Entry<String,Long> c:incoming.counts.entrySet())totals.put(c.getKey(),Math.max(totals.getOrDefault(c.getKey(),0L),c.getValue()));
   Map<Integer,Map<String,Long>> days=new TreeMap<>(left.buckets);for(Map.Entry<Integer,Map<String,Long>> b:right.buckets.entrySet()){Map<String,Long> values=new LinkedHashMap<>(days.getOrDefault(b.getKey(),Collections.emptyMap()));for(Map.Entry<String,Long> c:b.getValue().entrySet())values.put(c.getKey(),Math.max(values.getOrDefault(c.getKey(),0L),c.getValue()));days.put(b.getKey(),values);}
   return new Entry(reading,text,generation,deleted||incoming.deleted,totals,newestPin.pinned,newestPin.pinVersion,days);
  }
 }
 private Map<String,Entry> entries=new LinkedHashMap<>();
 private LearningCapacityProfiles.Profile capacity;
 RecentLearning(){this(LearningCapacityProfiles.LEGACY_5000);}
 RecentLearning(LearningCapacityProfiles.Profile profile){capacity=LearningCapacityMetadata.checked(profile);}
 LearningCapacityProfiles.Profile capacityProfile(){return capacity;}
 void upgradeCapacity(LearningCapacityProfiles.Profile profile)throws IOException{
  profile=LearningCapacityMetadata.checked(profile);LearningCapacityMetadata.allowMerge(profile,capacity);
  require(entries.size()<=profile.recentTermRows,"Recent capacity exceeded");int components=0;
  for(Entry entry:entries.values()){entry.validate();for(Map<String,Long> bucket:entry.buckets.values())components+=bucket.size();require(components<=profile.recentComponents,"Recent component capacity exceeded");}
  capacity=profile;
 }
 List<Entry> entries(){return Collections.unmodifiableList(new ArrayList<>(entries.values()));}
 Entry get(String reading,String text){return entries.get(nfc(reading.toLowerCase(Locale.ROOT)+'\u001f'+text));}
 RecentLearning copy(){RecentLearning next=new RecentLearning(capacity);next.entries=new LinkedHashMap<>(entries);return next;}
 void merge(RecentLearning incoming,Policy policy)throws IOException{LearningCapacityMetadata.allowMerge(capacity,incoming.capacity);merge(incoming.entries(),policy);}
 void merge(List<Entry> incoming,Policy policy)throws IOException{
  require(incoming.size()<=capacity.recentTermRows,"Recent archive oversized");Map<String,Entry> next=new LinkedHashMap<>(entries);Set<String> seen=new HashSet<>();
  for(Entry entry:incoming){entry.validate();require(seen.add(entry.id()),"Duplicate recent entry");Entry local=next.get(entry.id());next.put(entry.id(),local==null?entry.normalized(policy):local.merge(entry,policy));}
  validate(next,policy);entries=next;
 }
 void record(String reading,String text,String replica,long amount,Integer trustedDay,Policy policy)throws IOException{
  name(replica);require(amount>=0&&amount<=MAX_COUNT,"Invalid recent delta");if(amount==0)return;Entry fresh=Entry.fresh(reading,text),old=entries.getOrDefault(fresh.id(),fresh).normalized(policy);if(old.deleted)return;
  String id=nfc(replica);Map<String,Long> counts=new LinkedHashMap<>(old.counts);long baseline=counts.getOrDefault(id,0L),increment=Math.min(amount,MAX_COUNT-baseline);counts.put(id,baseline+increment);
  Map<Integer,Map<String,Long>> days=new TreeMap<>(old.buckets);if(increment>0&&trustedDay!=null&&policy.accepts(trustedDay)){Map<String,Long> bucket=new LinkedHashMap<>(days.getOrDefault(trustedDay,Collections.emptyMap()));bucket.put(id,bucket.getOrDefault(id,0L)+increment);days.put(trustedDay,bucket);}
  Map<String,Entry> next=new LinkedHashMap<>(entries);next.put(old.id(),new Entry(old.reading,old.text,old.generation,false,counts,old.pinned,old.pinVersion,days));validate(next,policy);entries=next;
 }
 /** Confirmed-output owns dated buckets; legacy checkpoint owns cumulative frequency.
  * Date evidence may arrive before or after that checkpoint without adding its delta twice. */
 static final class SelectionDelta {
  final String reading,text,replica;final Integer day;final BigInteger expectedGeneration;
  SelectionDelta(String reading,String text,String replica,Integer day){this(reading,text,replica,day,null);}
  SelectionDelta(String reading,String text,String replica,Integer day,BigInteger generation){this.reading=reading;this.text=text;this.replica=replica;this.day=day;expectedGeneration=generation;}
 }
 void recordConfirmedSelection(String reading,String text,String replica,Integer day,Policy policy)throws IOException{recordConfirmedSelections(Collections.singletonList(new SelectionDelta(reading,text,replica,day)),policy);}
 void recordConfirmedSelections(List<SelectionDelta> events,Policy policy)throws IOException{
  require(events.size()<=capacity.recentTermRows,"Recent batch oversized");Map<String,Entry> next=new LinkedHashMap<>(entries);
  for(SelectionDelta event:events){name(event.replica);Integer day=event.day;if(day==null||!policy.accepts(day))continue;Entry fresh=Entry.fresh(event.reading,event.text),old=next.getOrDefault(fresh.id(),fresh).normalized(policy);if(old.deleted||event.expectedGeneration!=null&&!event.expectedGeneration.equals(old.generation))continue;
   String id=nfc(event.replica);long known=0;for(Map<String,Long> bucket:old.buckets.values())known+=bucket.getOrDefault(id,0L);if(known>=MAX_COUNT)continue;
   Map<String,Long> counts=new LinkedHashMap<>(old.counts);counts.put(id,Math.max(counts.getOrDefault(id,0L),known+1));
   Map<Integer,Map<String,Long>> days=new TreeMap<>(old.buckets);Map<String,Long> bucket=new LinkedHashMap<>(days.getOrDefault(day,Collections.emptyMap()));bucket.put(id,bucket.getOrDefault(id,0L)+1);days.put(day,bucket);
   next.put(old.id(),new Entry(old.reading,old.text,old.generation,false,counts,old.pinned,old.pinVersion,days));
  }
  validate(next,policy);entries=next;
 }
 private void validate(Map<String,Entry> next,Policy policy)throws IOException{require(next.size()<=capacity.recentTermRows,"Recent capacity exceeded");int components=0;for(Map.Entry<String,Entry> item:next.entrySet()){Entry e=item.getValue().normalized(policy);item.setValue(e);e.validate();for(Map.Entry<Integer,Map<String,Long>> b:e.buckets.entrySet())if(policy.accepts(b.getKey()))components+=b.getValue().size();require(components<=capacity.recentComponents,"Recent component capacity exceeded");}}
 static final class ScoringSnapshot {
  private final Map<String,Entry> words;
  ScoringSnapshot(Map<String,Entry> words){this.words=Collections.unmodifiableMap(new HashMap<>(words));}
  Entry get(String reading,String text){return words.get(nfc(reading.toLowerCase(Locale.ROOT)+'\u001f'+text));}
  double score(String reading,String text,Policy policy){return scoreEntry(get(reading,text),policy);}
 }
 ScoringSnapshot scoringSnapshot(){return new ScoringSnapshot(entries);}
 double score(String reading,String text,Policy policy){return scoreEntry(get(reading,text),policy);}
 private static double scoreEntry(Entry e,Policy policy){if(e==null||e.deleted)return 0;double historical=.20*Math.log1p(e.frequency())/Math.log1p(MAX_COUNT),shortTerm=0,longTerm=0;
  if(policy!=null)for(Map.Entry<Integer,Map<String,Long>> b:e.buckets.entrySet())if(policy.accepts(b.getKey())){double age=policy.referenceDay-b.getKey(),count=0;for(long n:b.getValue().values())count+=n;if(age<7)shortTerm+=count*Math.pow(2,-age/2);longTerm+=count*Math.pow(2,-age/30);}
  return historical+.55*shortTerm/(shortTerm+4)+.25*longTerm/(longTerm+30);
 }
 static boolean canPublish(Set<String> activeWriters,Map<String,Set<String>> authenticated){return !activeWriters.isEmpty()&&activeWriters.stream().allMatch(id->!id.isEmpty()&&authenticated.getOrDefault(id,Collections.emptySet()).contains("learning-recency-v2"));}
}
