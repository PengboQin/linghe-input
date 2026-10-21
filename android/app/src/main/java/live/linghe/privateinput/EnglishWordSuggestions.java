package live.linghe.privateinput;
import java.util.*;
/** Port of Apple EnglishWordSuggestions: two-edit budget and QWERTY key distance. */
final class EnglishWordSuggestions {
 private static final String[] LINES={"qwertyuiop","asdfghjkl","zxcvbnm"};private static final double[] OFFSETS={0,.25,.75};
 static Double correctionCost(String input,String word){if(!input.matches("[a-z]{3,48}")||!word.matches("[a-z]{2,48}")||Math.abs(input.length()-word.length())>2)return null;int budget=input.length()>=5?2:1,n=input.length(),m=word.length();double[][][] cost=new double[n+1][m+1][budget+1];for(double[][] row:cost)for(double[] column:row)Arrays.fill(column,Double.POSITIVE_INFINITY);cost[0][0][0]=0;
  for(int i=0;i<=n;i++)for(int j=0;j<=m;j++){if(i+j==0)continue;if(i>0)add(cost,i,j,i-1,j,i>1&&input.charAt(i-1)==input.charAt(i-2)?.55:1,1,budget);if(j>0)add(cost,i,j,i,j-1,j>1&&word.charAt(j-1)==word.charAt(j-2)?.55:1,1,budget);if(i>0&&j>0){boolean equal=input.charAt(i-1)==word.charAt(j-1);add(cost,i,j,i-1,j-1,equal?0:near(input.charAt(i-1),word.charAt(j-1))?.55:1.25,equal?0:1,budget);}if(i>1&&j>1&&input.charAt(i-1)==word.charAt(j-2)&&input.charAt(i-2)==word.charAt(j-1))add(cost,i,j,i-2,j-2,.65,1,budget);}
  double value=Double.POSITIVE_INFINITY;for(double v:cost[n][m])value=Math.min(value,v);double ceiling=n>=5?2.1:n==4?1.3:.8;return value>0&&value<=ceiling?value:null;
 }
 private static void add(double[][][] cost,int i,int j,int fromI,int fromJ,double extra,int edit,int budget){for(int used=0;used+edit<=budget;used++)cost[i][j][used+edit]=Math.min(cost[i][j][used+edit],cost[fromI][fromJ][used]+extra);}
 private static double[] position(char c){for(int i=0;i<LINES.length;i++){int column=LINES[i].indexOf(c);if(column>=0)return new double[]{column+OFFSETS[i],i};}return null;}
 private static boolean near(char a,char b){double[] x=position(a),y=position(b);return x!=null&&y!=null&&Math.hypot(x[0]-y[0],x[1]-y[1])<=1.3;}
 static List<String> suggestions(String prefix,List<String> words){if(!prefix.matches("[A-Za-z]{2,32}"))return Collections.emptyList();String lower=prefix.toLowerCase(Locale.ROOT);ArrayList<String> completions=new ArrayList<>();Set<String> seen=new HashSet<>();for(String word:words){String key=word.toLowerCase(Locale.ROOT);if(EnglishSuggestions.valid(word)&&key.startsWith(lower)&&!key.equals(lower)&&seen.add(key))completions.add(key);}
  completions.sort(Comparator.comparingInt(word->word.length()-prefix.length()>3?1:0));
  class Correction{final String word;final double cost;final int order;Correction(String w,double c,int i){word=w;cost=c;order=i;}}
  ArrayList<Correction> corrections=new ArrayList<>();if(prefix.length()>=3)for(int i=0;i<words.size();i++){String word=words.get(i).toLowerCase(Locale.ROOT);if(word.equals(lower)||seen.contains(word))continue;Double cost=correctionCost(lower,word);if(cost!=null&&seen.add(word))corrections.add(new Correction(word,cost,i));}corrections.sort((a,b)->{int c=Double.compare(a.cost,b.cost);return c==0?Integer.compare(a.order,b.order):c;});
  ArrayList<String> result=new ArrayList<>(completions.subList(0,Math.min(completions.size(),6)));double best=corrections.isEmpty()?0:corrections.get(0).cost;for(Correction value:corrections)if(value.cost<=best+.6)result.add(value.word);if(completions.size()>6)result.addAll(completions.subList(6,completions.size()));if(result.size()>12)result=new ArrayList<>(result.subList(0,12));for(int i=0;i<result.size();i++){String word=result.get(i);if(prefix.equals(prefix.toUpperCase(Locale.ROOT)))word=word.toUpperCase(Locale.ROOT);else if(Character.isUpperCase(prefix.charAt(0)))word=Character.toUpperCase(word.charAt(0))+word.substring(1);result.set(i,word);}return result;
 }
}
