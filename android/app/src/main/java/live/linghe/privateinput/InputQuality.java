package live.linghe.privateinput;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.function.BooleanSupplier;

/** Dictionary-validated recall. Temporary context only affects bounded ranking. */
final class InputQuality {
 static final class Repair {
  final String raw,spelling,text,reading,remainder;final double score;final boolean prefixCompletion;
  Repair(String raw,String spelling,String text,String reading,String remainder,double score){this(raw,spelling,text,reading,remainder,score,false);}
  Repair(String raw,String spelling,String text,String reading,String remainder,double score,boolean prefixCompletion){this.raw=raw;this.spelling=spelling;this.text=text;this.reading=reading;this.remainder=remainder;this.score=score;this.prefixCompletion=prefixCompletion;}
 }
 private final Set<String> syllables;
 private final PublicLanguageData.Nine frequency;
 private final PublicLanguageData.Continuations continuations;
 private final PinyinCorrector corrector;
 InputQuality(File folder)throws IOException {
  syllables=new HashSet<>(Files.readAllLines(new File(folder,"pinyin-syllables.txt").toPath(),StandardCharsets.UTF_8));syllables.remove("");
  frequency=new PublicLanguageData.Nine(new File(folder,"nine-lexicon.bin"));
  continuations=new PublicLanguageData.Continuations(new File(folder,"continuation.bin"));
  corrector=new PinyinCorrector(syllables,text->frequency.frequency(code(text)));
 }
 private static String code(String reading){String code=NineSpelling.encode(reading);return code==null?"":code;}
 static String normalized(String reading){StringBuilder value=new StringBuilder();for(String part:reading.split("[ '\t]+"))value.append(PinyinMatch.canonical(part));return value.toString();}
 boolean fullySpelled(String reading) {
  if(reading.trim().isEmpty())return false;
  for(String part:reading.trim().split("[ ']+"))if(!syllables.contains(PinyinMatch.canonical(part)))return false;
  return true;
 }
 boolean exact(String raw,String reading,boolean nine) {
  return fullySpelled(reading)&&(nine?raw.equals(code(reading)):PinyinMatch.isFullSpelling(raw,reading));
 }
 private static String tail(long session,String[][] state,boolean nine) {
  if(state.length==0||state[0].length<5)return "";
  String raw=state[0][2],selected=state[0][4];long start=NativeCore.editableStart(session);
  if(start<0&&!nine&&selected.isEmpty())start=0;
  // A nonempty spelling prefix without selected Chinese may be an explicit
  // syllable lock. Until a complete assembly exists, never drop that prefix.
  if(start<0||start>raw.length()||(start>0&&selected.isEmpty()))return "";
  String tail=raw.substring((int)start);
  return tail.matches(nine?"[2-9]+":"[a-z]+")?tail:"";
 }
 /** High-confidence public completion of unfinished cross-syllable codes.
  * Pure appended digits only: repeated presses are never collapsed or edited. */
 List<Repair> prefixCompletions(long session,String[][] state,boolean protectedHead,java.util.function.ToLongFunction<String> essayFrequency){
  if(protectedHead||!NativeCore.atEnd(session)||state.length<1)return Collections.emptyList();
  return prefixCompletions(tail(session,state,true),state,protectedHead,essayFrequency,code->NativeCore.query(session,code,true,8));
 }
 List<Repair> prefixCompletions(String source,String[][] state,boolean protectedHead,java.util.function.ToLongFunction<String> essayFrequency,java.util.function.Function<String,String[][]> query){
  if(protectedHead||state.length<1||!source.matches("[2-9]{3,12}"))return Collections.emptyList();
  long head=state.length>1?essayFrequency.applyAsLong(state[1][1]):0;
  if(head>=3000)return Collections.emptyList();
  ArrayList<Repair> result=new ArrayList<>();Set<String> seen=new HashSet<>();
  for(PublicLanguageData.Nine.Completion proposal:frequency.completions(source,6,4)){
   for(String[] row:query.apply(proposal.input)){
    long weight=essayFrequency.applyAsLong(row[1]);
    if(weight<3000||weight<=head*4||!exact(proposal.input,row[2],true)||!code(row[2]).startsWith(source)||row[1].codePointCount(0,row[1].length())!=row[2].trim().split("[ ']+").length||!seen.add(row[1]))continue;
    result.add(new Repair(state[0][2],normalized(row[2]),row[1],row[2],"",weight,true));
   }
  }
  result.sort((a,b)->Double.compare(b.score,a.score));
  return new ArrayList<>(result.subList(0,Math.min(3,result.size())));
 }
 static String prefixReading(String rawCode,String reading){
  String full=NineSpelling.encode(reading);if(full==null||!full.startsWith(rawCode))return "";
  ArrayList<String> parts=new ArrayList<>();int remaining=rawCode.length();
  for(String syllable:reading.trim().split("[ ']+")){
   if(remaining==0)break;int count=Math.min(remaining,syllable.length());parts.add(syllable.substring(0,count));remaining-=count;
  }
  return remaining==0?String.join("'",parts):"";
 }
 List<Repair> repairs(long session,String[][] nativeState,boolean nine,String before,String after,BooleanSupplier cancelled) {
  String raw=nativeState[0][2],tail=tail(session,nativeState,nine);
  if(tail.length()<2||tail.length()>96||cancelled.getAsBoolean())return Collections.emptyList();
  boolean ordinary=nativeState.length>1,hasExact=false;
  for(int i=1;i<Math.min(nativeState.length,33);i++)if(exact(tail,nativeState[i][2],nine)){hasExact=true;break;}
  if(!nine&&tail.length()<10&&!tail.matches(".*([a-z])\\1.*")&&hasExact)return Collections.emptyList();
  List<Repair> result=new ArrayList<>();
  repeatedHeads(session,nativeState,tail,nine,result,cancelled);
  if(nine&&tail.length()<=12) {
   // Dictionary frequencies select the strongest public hypotheses; reserve
   // each edit category so omissions are not crowded out by substitutions.
   List<NineSpelling.Alternative> alternatives=nineAlternatives(tail);
   for(NineSpelling.Alternative alternative:alternatives) {
    if(cancelled.getAsBoolean())return Collections.emptyList();
    collect(session,nativeState,tail,alternative.input,alternative.cost,true,before,after,result);
   }
  } else if(!nine) {
   for(PinyinCorrector.Proposal proposal:corrector.proposals(tail,64,cancelled)) {
    if(cancelled.getAsBoolean())return Collections.emptyList();
    collect(session,nativeState,tail,proposal.spelling,proposal.cost,false,before,after,result);
   }
  }
  result.sort((a,b)->{int c=Double.compare(b.score,a.score);return c!=0?c:a.text.compareTo(b.text);});
  if(result.size()>16) {
   List<Repair> selected=new ArrayList<>(result.subList(0,12));Set<String> seen=new HashSet<>();for(Repair value:selected)seen.add(value.text);
   // Preserve output recall too, not just the query budget. A phrase-frequency
   // index has sparse single-character evidence; do not silently erase an
   // entire error category at the last top-16 cutoff.
   for(int kind=0;kind<4;kind++)for(Repair value:result) {
    String spelling=nine?code(value.reading):value.spelling;
    if(category(tail,spelling)==kind&&!seen.contains(value.text)){selected.add(value);seen.add(value.text);break;}
   }
   for(Repair value:result)if(selected.size()<16&&seen.add(value.text))selected.add(value);
   result=selected;
  }
  // An undecodable tail should not make its exact readable prefix unusable.
  // Keep all unmatched keys, including the malformed suffix, after selection.
  if(result.isEmpty()&&!ordinary) {
   for(int cut=Math.min(32,tail.length()-1);cut>=1;cut--) {
    if(cancelled.getAsBoolean())return Collections.emptyList();
    String prefix=tail.substring(0,cut);
    for(String[] row:NativeCore.query(session,prefix,nine,8))if(exact(prefix,row[2],nine)) {
     result.add(new Repair(raw,normalized(row[2]),row[1],row[2],tail.substring(cut),0));
    }
    if(!result.isEmpty())break;
   }
  }
  return result;
 }
 // Repeated initials are deliberate input, not insertion/deletion errors.
 // Each result owns its consumed prefix and keeps every unmatched tail key.
 static List<Repair> immediateRepeatedHeads(long session,String[][] state,boolean nine) {
  if(!nine||state.length!=1)return Collections.emptyList();String raw=tail(session,state,true);
  if(raw.length()<2||raw.length()>96)return Collections.emptyList();
  List<Repair> result=new ArrayList<>();repeatedHeads(session,state,raw,true,result,()->false,reading->reading.matches("[a-z]+(?:[ ']+[a-z]+)*"));result.sort((a,b)->{int c=Double.compare(b.score,a.score);return c!=0?c:a.text.compareTo(b.text);});return new ArrayList<>(result.subList(0,Math.min(32,result.size())));
 }
 private void repeatedHeads(long session,String[][] state,String raw,boolean nine,List<Repair> result,BooleanSupplier cancelled) {repeatedHeads(session,state,raw,nine,result,cancelled,this::fullySpelled);}
 private static void repeatedHeads(long session,String[][] state,String raw,boolean nine,List<Repair> result,BooleanSupplier cancelled,java.util.function.Predicate<String> fullySpelled) {
  if(raw.length()<2||raw.length()>96)return;int run=1;while(run<raw.length()&&raw.charAt(run)==raw.charAt(0))run++;
  if(run<2)return;LinkedHashSet<Integer> cuts=new LinkedHashSet<>();
  if(run<raw.length()){if(run>=3&&run-1<=8)cuts.add(run-1);if(run<=8)cuts.add(run);}else if(run<=8)cuts.add(run);
  if(cuts.isEmpty()&&run>8)cuts.add(8);if(cuts.isEmpty())return;
  String letters=nine?new String[]{"abc","def","ghi","jkl","mno","pqrs","tuv","wxyz"}[raw.charAt(0)-'2']:raw.substring(0,1);
  int queries=0;
  for(int cut:cuts){String suffix=raw.substring(cut);List<String[]> tails=new ArrayList<>();if(!suffix.isEmpty()&&suffix.length()<=16)for(String[] row:NativeCore.query(session,suffix,nine,96))if(fullySpelled.test(row[2])&&(nine?suffix.equals(code(row[2])):PinyinMatch.isFullSpelling(suffix,row[2]))&&tails.size()<8)tails.add(row);
   for(int letterIndex=0;letterIndex<letters.length()&&queries<8;letterIndex++){if(cancelled.getAsBoolean())return;char letter=letters.charAt(letterIndex);if("aeiouv".indexOf(letter)>=0)continue;String initials=String.join("",Collections.nCopies(cut,String.valueOf(letter)));queries++;
    int rank=0;for(String[] head:NativeCore.initials(session,initials,32)){if(cancelled.getAsBoolean())return;String[] parts=head[2].trim().split("[ ']+");if(parts.length!=cut||head[1].codePointCount(0,head[1].length())!=cut||!fullySpelled.test(head[2]))continue;boolean valid=true;for(String part:parts)if(part.charAt(0)!=letter){valid=false;break;}if(!valid)continue;
     if(rank>=4)break;boolean uniform=head[1].codePoints().distinct().count()==1;double priority=(uniform?2:0)-rank++*.1;
     int tailRank=0;for(String[] tail:tails){String reading=head[2]+" "+tail[2];result.add(new Repair(state[0][2],normalized(reading),head[1]+tail[1],reading,"",8+priority+suffix.length()*.15-tailRank++*.08));}
     result.add(new Repair(state[0][2],normalized(head[2]),head[1],head[2],suffix,priority));if(result.size()>=256)return;
    }
   }
  }
 }
 private List<NineSpelling.Alternative> nineAlternatives(String raw) {
  // Exhaustively enumerate one edit at <=12 keys; query only 32 Rime drafts.
  LinkedHashMap<String,NineSpelling.Alternative> all=new LinkedHashMap<>();
  for(int i=0;i<raw.length();i++) {
   offer(raw,raw.substring(0,i)+raw.substring(i+1),all);
   for(char digit='2';digit<='9';digit++)if(digit!=raw.charAt(i))offer(raw,raw.substring(0,i)+digit+raw.substring(i+1),all);
   if(i+1<raw.length()){char[] chars=raw.toCharArray();char c=chars[i];chars[i]=chars[i+1];chars[i+1]=c;offer(raw,new String(chars),all);}
  }
  for(int i=0;i<=raw.length();i++)for(char digit='2';digit<='9';digit++)offer(raw,raw.substring(0,i)+digit+raw.substring(i),all);
  List<NineSpelling.Alternative> ranked=new ArrayList<>(all.values());ranked.sort((a,b)->{
   double x=Math.log1p(frequency.frequency(a.input))-a.cost*1.5,y=Math.log1p(frequency.frequency(b.input))-b.cost*1.5;
   int c=Double.compare(y,x);return c!=0?c:a.input.compareTo(b.input);
  });
  LinkedHashMap<String,NineSpelling.Alternative> selected=new LinkedHashMap<>();
  for(NineSpelling.Alternative value:ranked.subList(0,Math.min(8,ranked.size())))selected.put(value.input,value);
  for(int category=0;category<4;category++)for(NineSpelling.Alternative value:ranked)if(category(raw,value.input)==category&&!selected.containsKey(value.input)){selected.put(value.input,value);break;}
  for(NineSpelling.Alternative value:NineSpelling.alternatives(raw,128))if(selected.size()<32)selected.putIfAbsent(value.input,value);
  for(NineSpelling.Alternative value:ranked)if(selected.size()<32)selected.putIfAbsent(value.input,value);
  return new ArrayList<>(selected.values());
 }
 private void offer(String raw,String next,Map<String,NineSpelling.Alternative> result) {
  if(raw.equals(next)||result.containsKey(next)||frequency.frequency(next)==0)return;
  Double cost=NineSpelling.editCost(raw,next);
  if(cost!=null&&raw.length()==next.length()+1)for(int i=1;i<raw.length();i++)if(raw.charAt(i)==raw.charAt(i-1)&&(raw.substring(0,i)+raw.substring(i+1)).equals(next)){cost=.9;break;}
  if(cost!=null)result.put(next,new NineSpelling.Alternative(next,cost));
 }
 private static int category(String source,String target) {
  if(target.length()>source.length())return 0;if(target.length()<source.length())return 1;
  int different=0;for(int i=0;i<source.length();i++)if(source.charAt(i)!=target.charAt(i))different++;return different==2?2:3;
 }
 private void collect(long session,String[][] state,String tail,String query,double cost,boolean nine,String before,String after,List<Repair> result) {
  int rank=0;
  for(String[] row:NativeCore.query(session,query,nine,16)) {
   int index=rank++;if(row[1].isEmpty()||!exact(query,row[2],nine))continue;
   // Native order stays the primary homophone signal. Public two-sided phrase
   // affinity is a bounded lexical cue, not a neural semantic model.
   long publicFrequency=frequency.frequency(code(row[2]));
   if(!state[0][4].isEmpty()) {
    String lockedCode=NineSpelling.rawCode(state[0][2].substring(0,state[0][2].length()-tail.length()));
    if(lockedCode!=null)publicFrequency=Math.max(publicFrequency,frequency.frequency(lockedCode+code(row[2])));
   }
   // The compact phrase index intentionally lacks many common single words.
   // Missing evidence is neutral; it must not veto a real Rime candidate.
   double lexical=Math.min(1,Math.log1p(publicFrequency)*.08);
   double score=-3-cost*3-index*.8+lexical+continuations.affinity(new ContextWindow(before+state[0][4],after).before,row[1],after);
   Repair value=new Repair(state[0][2],normalized(row[2]),row[1],row[2],"",score);
   int old=-1;for(int i=0;i<result.size();i++)if(result.get(i).text.equals(value.text)){old=i;break;}
   if(old<0)result.add(value);else if(result.get(old).score<score)result.set(old,value);
  }
 }
 String[][] merged(String[][] ordinary,String[][] augmented,List<Repair> repairs,boolean nine,Map<String,Repair> plans) {
  plans.clear();if(repairs.isEmpty())return augmented;
  ArrayList<String[]> rows=new ArrayList<>();rows.add(augmented[0].clone());Set<String> used=new HashSet<>();
  for(int i=1;i<augmented.length;i++)if(augmented[i][0].startsWith("custom:")&&used.add(augmented[i][1]))rows.add(augmented[i]);
  String raw=ordinary[0][2];boolean complete=false;
  for(int i=1;i<Math.min(ordinary.length,33);i++)if(exact(raw,ordinary[i][2],nine)){complete=true;break;}
  int kept=0,budget=raw.length()>=8&&raw.matches(".*[aeiou].*")?1:Integer.MAX_VALUE;
  for(int i=1;i<Math.min(ordinary.length,33);i++) {
   String[] row=ordinary[i];boolean protect=complete?kept<3:(!nine&&kept<9&&PinyinMatch.covers(raw,row[2],budget));
   if(protect&&used.add(row[1])){rows.add(row);kept++;}
  }
  for(Repair repair:repairs)if(used.add(repair.text)) {
   String id=repairID(repair);plans.put(id,repair);rows.add(new String[]{id,repair.text,repair.reading});
  }
  for(int i=1;i<augmented.length;i++)if(used.add(augmented[i][1]))rows.add(augmented[i]);
  if(nine&&rows.size()>1&&rows.get(1)[0].startsWith("repair:"))rows.get(0)[3]=ordinary[0][4]+rows.get(1)[2].replace(' ', '\'');
  return rows.toArray(new String[0][]);
 }
 static String[][] mergeImmediateRepeated(String[][] state,List<Repair> repairs,Map<String,Repair> plans){
  if(state.length!=1||repairs.isEmpty())return state;ArrayList<String[]> rows=new ArrayList<>();rows.add(state[0].clone());Set<String> used=new HashSet<>();for(Repair repair:repairs)if(used.add(repair.text)){String id=repairID(repair);plans.put(id,repair);rows.add(new String[]{id,repair.text,repair.reading});}return rows.toArray(new String[0][]);
 }
 static String repairID(Repair repair) {
  try {
   String binding=repair.raw+"\u0000"+repair.spelling+"\u0000"+repair.text+"\u0000"+repair.reading+"\u0000"+repair.remainder+"\u0000"+repair.prefixCompletion;
   byte[] digest=java.security.MessageDigest.getInstance("SHA-256").digest(binding.getBytes(StandardCharsets.UTF_8));return "repair:"+Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
  }catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException("SHA-256 unavailable",impossible);}
 }
 List<PublicLanguageData.Suggestion> suggestions(String before){return continuations.suggestions(before,24);}
}
