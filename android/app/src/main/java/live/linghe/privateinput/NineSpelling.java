package live.linghe.privateinput;

import java.util.*;

/** Same bounded edit rules as NineKeySpelling; proposals never replace live input. */
final class NineSpelling {
 private static final String KEYS="22233344455566677778889999";
 static String encode(String reading) {
  StringBuilder result=new StringBuilder();
  for(char c:reading.toLowerCase(Locale.ROOT).toCharArray()) {
   if(c==' '||c=='\'')continue;
   if(c<'a'||c>'z')return null;
   result.append(KEYS.charAt(c-'a'));
  }
  return result.length()==0?null:result.toString();
 }
 static boolean isCode(String text){return text!=null&&!text.isEmpty()&&text.matches("[2-9]+");}
 static String rawCode(String input) {
  StringBuilder result=new StringBuilder();
  for(char c:input.toCharArray()) {
   if(c==' '||c=='\'')continue;
   if(c>='2'&&c<='9')result.append(c);
   else {String value=encode(String.valueOf(c));if(value==null)return null;result.append(value);}
  }
  return result.length()==0?null:result.toString();
 }
 static final class Alternative {
  final String input;final double cost;
  Alternative(String input,double cost){this.input=input;this.cost=cost;}
 }
 private static void add(List<List<Alternative>> buckets,Set<String> seen,String input,double cost,int category) {
  if(seen.add(input))buckets.get(category).add(new Alternative(input,cost));
 }
 static List<Alternative> alternatives(String input,int limit) {
  if(!isCode(input)||input.length()<2||input.length()>12||limit<=0)return Collections.emptyList();
  List<List<Alternative>> buckets=new ArrayList<>();for(int i=0;i<4;i++)buckets.add(new ArrayList<>());
  Set<String> seen=new HashSet<>();seen.add(input);
  for(int i=input.length()-1;i>=0;i--) {
   int digit=input.charAt(i)-'0',row=(digit-1)/3,column=(digit-1)%3;
   for(int n=2;n<=9;n++)if(n!=digit) {
    int dr=Math.abs((n-1)/3-row),dc=Math.abs((n-1)%3-column);
    if(dr<=1&&dc<=1)add(buckets,seen,input.substring(0,i)+n+input.substring(i+1),dr+dc==1?1:1.4,0);
   }
   boolean repeated=(i>0&&input.charAt(i-1)==input.charAt(i))||(i+1<input.length()&&input.charAt(i+1)==input.charAt(i));
   add(buckets,seen,input.substring(0,i)+input.substring(i+1),repeated?.9:1.5,1);
  }
  for(int i=input.length()-1;i>=0;i--)add(buckets,seen,input.substring(0,i)+input.charAt(i)+input.substring(i),1.1,2);
  for(int i=0;i<input.length()-1;i++)if(input.charAt(i)!=input.charAt(i+1)) {
   char[] chars=input.toCharArray();char c=chars[i];chars[i]=chars[i+1];chars[i+1]=c;add(buckets,seen,new String(chars),1.2,3);
  }
  for(int i=input.length();i>=0;i--)for(int n=2;n<=9;n++)add(buckets,seen,input.substring(0,i)+n+input.substring(i),1.7,2);
  List<Alternative> result=new ArrayList<>();int[] positions=new int[4];int ceiling=Math.min(limit,128);
  while(result.size()<ceiling) {
   boolean advanced=false;
   for(int b=0;b<4;b++)if(positions[b]<buckets.get(b).size()) {
    result.add(buckets.get(b).get(positions[b]++));advanced=true;if(result.size()==ceiling)break;
   }
   if(!advanced)break;
  }
  return result;
 }
 private static Double neighbor(char a,char b) {
  int x=a-'0',y=b-'0',dr=Math.abs((x-1)/3-(y-1)/3),dc=Math.abs((x-1)%3-(y-1)%3);
  return dr<=1&&dc<=1?(dr+dc==1?1.0:1.4):null;
 }
 static Double editCost(String source,String target) {
  if(!isCode(source)||!isCode(target)||source.length()>128||target.length()>129)return null;
  if(source.equals(target))return 0.0;
  if(source.length()==target.length()) {
   List<Integer> different=new ArrayList<>();for(int i=0;i<source.length();i++)if(source.charAt(i)!=target.charAt(i))different.add(i);
   if(different.size()==1){int i=different.get(0);return neighbor(source.charAt(i),target.charAt(i));}
   if(different.size()==2){int i=different.get(0),j=different.get(1);if(j==i+1&&source.charAt(i)==target.charAt(j)&&source.charAt(j)==target.charAt(i))return 1.2;}
   return null;
  }
  if(Math.abs(source.length()-target.length())!=1)return null;
  String longer=source.length()>target.length()?source:target,shorter=source.length()>target.length()?target:source;
  int i=0,j=0;boolean skipped=false;
  while(i<longer.length()&&j<shorter.length()) {
   if(longer.charAt(i)==shorter.charAt(j)){i++;j++;}
   else if(!skipped){i++;skipped=true;}else return null;
  }
  return 1.5;
 }
 static Double jointEditCost(String source,String target) {
  Double single=editCost(source,target);if(single!=null)return single;
  if(!isCode(source)||!isCode(target)||source.length()>128||target.length()>128||Math.abs(source.length()-target.length())>2)return null;
  int width=target.length()+1;double[] previous2=new double[width*3];Arrays.fill(previous2,Double.POSITIVE_INFINITY);double[] previous=previous2.clone();
  for(int j=0;j<=Math.min(2,target.length());j++)previous[j*3+j]=j*1.5;
  for(int i=1;i<=source.length();i++) {
   double[] current=new double[width*3];Arrays.fill(current,Double.POSITIVE_INFINITY);if(i<=2)current[i]=i*1.5;
   for(int j=Math.max(1,i-2);j<=Math.min(target.length(),i+2);j++)for(int edits=0;edits<=2;edits++) {
    int at=j*3+edits;
    if(source.charAt(i-1)==target.charAt(j-1))current[at]=Math.min(current[at],previous[(j-1)*3+edits]);
    if(edits==0)continue;
    current[at]=Math.min(current[at],Math.min(previous[j*3+edits-1]+1.5,current[(j-1)*3+edits-1]+1.5));
    if(source.charAt(i-1)!=target.charAt(j-1)) {Double cost=neighbor(source.charAt(i-1),target.charAt(j-1));if(cost!=null)current[at]=Math.min(current[at],previous[(j-1)*3+edits-1]+cost);}
    if(i>1&&j>1&&source.charAt(i-1)==target.charAt(j-2)&&source.charAt(i-2)==target.charAt(j-1))current[at]=Math.min(current[at],previous2[(j-2)*3+edits-1]+1.2);
   }
   previous2=previous;previous=current;
  }
  double result=Math.min(previous[target.length()*3],Math.min(previous[target.length()*3+1],previous[target.length()*3+2]));
  return Double.isFinite(result)?result:null;
 }
}
