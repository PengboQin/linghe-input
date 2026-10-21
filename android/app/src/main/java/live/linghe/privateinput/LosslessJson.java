package live.linghe.privateinput;

import android.util.JsonReader;
import android.util.JsonToken;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;

/** Native streaming JSON with exact integer tokens, bounded depth and no duplicate keys. */
final class LosslessJson {
 static final BigInteger UINT64_MAX=new BigInteger("18446744073709551615");
 private int nodes;private final int maximumNodes;
 private LosslessJson(int maximumBytes){maximumNodes=Math.max(80000,Math.min(1000000,maximumBytes/4));}
 static String canonical(Object value)throws Exception {StringBuilder output=new StringBuilder();writeCanonical(value,output,0);return output.toString();}
 private static void writeCanonical(Object value,StringBuilder out,int depth)throws Exception {
  require(depth<=24);
  if(value==null||value==JSONObject.NULL){out.append("null");return;}
  if(value instanceof JSONObject){JSONObject object=(JSONObject)value;ArrayList<String> keys=new ArrayList<>();Iterator<String> names=object.keys();while(names.hasNext())keys.add(names.next());Collections.sort(keys);out.append('{');boolean comma=false;for(String key:keys){if(comma)out.append(',');comma=true;out.append(JSONObject.quote(key)).append(':');writeCanonical(object.get(key),out,depth+1);}out.append('}');return;}
  if(value instanceof JSONArray){JSONArray array=(JSONArray)value;out.append('[');for(int i=0;i<array.length();i++){if(i>0)out.append(',');writeCanonical(array.get(i),out,depth+1);}out.append(']');return;}
  if(value instanceof String){unicode((String)value);out.append(JSONObject.quote((String)value));return;}
  if(value instanceof Number){out.append(JSONObject.numberToString((Number)value));return;}
  if(value instanceof Boolean){out.append(value.toString());return;}
  throw new IOException("Invalid JSON value");
 }
 private static void require(boolean ok)throws IOException{if(!ok)throw new IOException("JSON格式不正确");}
 static JSONObject object(String encoded,int maximumBytes)throws IOException {
  require(encoded!=null&&encoded.getBytes(StandardCharsets.UTF_8).length<=maximumBytes);
  try(JsonReader reader=new JsonReader(new StringReader(encoded))) {
   reader.setLenient(false);Object value=new LosslessJson(maximumBytes).read(reader,0);
   require(value instanceof JSONObject&&reader.peek()==JsonToken.END_DOCUMENT);
   return (JSONObject)value;
  }catch(IOException error){throw error;}
  catch(Exception error){throw new IOException("JSON格式不正确");}
 }
 private Object read(JsonReader reader,int depth)throws Exception {
  require(depth<=24&&++nodes<=maximumNodes);
  switch(reader.peek()) {
   case BEGIN_OBJECT: {
    reader.beginObject();JSONObject object=new JSONObject();Set<String> keys=new HashSet<>();
    while(reader.hasNext()){String key=reader.nextName();unicode(key);require(keys.add(key));object.put(key,read(reader,depth+1));}
    reader.endObject();return object;
   }
   case BEGIN_ARRAY: {
    reader.beginArray();JSONArray array=new JSONArray();while(reader.hasNext())array.put(read(reader,depth+1));reader.endArray();return array;
   }
   case STRING:{String value=reader.nextString();unicode(value);return value;}
   case NUMBER: {
    String number=reader.nextString();require(number.length()<=128&&number.matches("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"));
    return number.indexOf('.')<0&&number.indexOf('e')<0&&number.indexOf('E')<0?new BigInteger(number):new BigDecimal(number);
   }
   case BOOLEAN:return reader.nextBoolean();
   case NULL:reader.nextNull();return JSONObject.NULL;
   default:throw new IOException("JSON格式不正确");
  }
 }
 static BigInteger unsigned(Object number)throws IOException {
  require(number instanceof Number);
  try {
   BigDecimal value=number instanceof BigDecimal?(BigDecimal)number:new BigDecimal(number.toString());
   require(value.signum()>=0);
   if(value.signum()==0)return BigInteger.ZERO;
   value=value.stripTrailingZeros();
   require(value.scale()<=0&&(long)value.precision()-(long)value.scale()<=20);
   BigInteger integer=value.toBigIntegerExact();require(integer.compareTo(UINT64_MAX)<=0);return integer;
  }catch(ArithmeticException|NumberFormatException error){throw new IOException("整数超出支持范围");}
 }
 static void unicode(String value)throws IOException {
  for(int i=0;i<value.length();i++) {
   char c=value.charAt(i);
   if(Character.isHighSurrogate(c)){require(i+1<value.length()&&Character.isLowSurrogate(value.charAt(++i)));}
   else require(!Character.isLowSurrogate(c));
  }
 }
}
