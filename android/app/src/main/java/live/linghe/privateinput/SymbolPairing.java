package live.linghe.privateinput;
import java.util.*;
/** Deliberate symbol taps only. Candidate output, paste and shared text stay raw. */
final class SymbolPairing {
 static final class Plan{final String insertedText;final int caretBack;Plan(String text,int back){insertedText=text;caretBack=back;}}
 private static final Map<String,String> PAIRS;
 static{Map<String,String> m=new LinkedHashMap<>();String[][] pairs={{"(",")"},{"（","）"},{"[","]"},{"【","】"},{"{","}"},{"《","》"},{"〈","〉"},{"「","」"},{"『","』"},{"“","”"},{"‘","’"},{"\"","\""}};for(String[] pair:pairs)m.put(pair[0],pair[1]);PAIRS=Collections.unmodifiableMap(m);}
 static Plan plan(String symbol,boolean autoPair,boolean caretInside){String closer=autoPair?PAIRS.get(symbol):null;return closer==null?new Plan(symbol,0):new Plan(symbol+closer,caretInside?closer.length():0);}
}
