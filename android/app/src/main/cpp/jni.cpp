#include <jni.h>
#include <string>
#include <vector>
#include <codecvt>
#include <locale>
#include <unordered_map>
#include <algorithm>
#include <mutex>
#include "private_input.h"
#include "learning_capacity_profiles.h"
namespace {
struct Config { bool nine=false, private_mode=false; PI_Session probe=0; bool probe_nine=false; };
std::unordered_map<PI_Session,Config> configs;
std::recursive_mutex wrappers;
std::string utf8(JNIEnv* e,jstring input) {
 if(!input)return {};
 const jchar* raw=e->GetStringChars(input,nullptr);if(!raw)return {};
 std::u16string value(reinterpret_cast<const char16_t*>(raw),e->GetStringLength(input));
 e->ReleaseStringChars(input,raw);
 try {std::wstring_convert<std::codecvt_utf8_utf16<char16_t>,char16_t> cv;return cv.to_bytes(value);}catch(...){return {};}
}
std::string normalized(std::string text) {text.erase(std::remove_if(text.begin(),text.end(),[](char c){return c==' '||c=='\'';}),text.end());return text;}
void destroy(PI_Session session) {
 auto old=configs.find(session);
 if(old!=configs.end()){if(old->second.probe)pi_destroy_session(old->second.probe);configs.erase(old);}
 pi_destroy_session(session);
}
jobjectArray strings(JNIEnv* e,const std::vector<std::string>& values);

jstring str(JNIEnv* e,const char* raw){try{std::wstring_convert<std::codecvt_utf8_utf16<char16_t>,char16_t> cv;auto text=cv.from_bytes(raw?raw:"");return e->NewString(reinterpret_cast<const jchar*>(text.data()),text.size());}catch(...){return e->NewString(nullptr,0);}}
jobjectArray strings(JNIEnv* e,const std::vector<std::string>& values) {
 auto type=e->FindClass("java/lang/String");auto array=e->NewObjectArray(values.size(),type,nullptr);
 for(size_t i=0;i<values.size();i++){auto value=str(e,values[i].c_str());e->SetObjectArrayElement(array,i,value);e->DeleteLocalRef(value);}
 e->DeleteLocalRef(type);return array;
}
}
extern "C" {
JNIEXPORT jlong JNICALL Java_live_linghe_privateinput_NativeCore_create(JNIEnv*e,jclass,jstring shared,jstring user){
 std::lock_guard<std::recursive_mutex> lock(wrappers);auto a=utf8(e,shared),b=utf8(e,user);const auto&profile=private_input::learning_capacity::expanded_10000;if(!pi_initialize(a.c_str(),b.c_str(),0)||pi_set_learning_capacity_profile(profile.id.data(),profile.version)!=1)return 0;auto session=pi_create_session();if(session)configs.emplace(session,Config{});return session;
}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_destroy(JNIEnv*,jclass,jlong session){std::lock_guard<std::recursive_mutex> lock(wrappers);if(session)destroy(session);if(!pi_active_session_count())pi_finalize();}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_key(JNIEnv*,jclass,jlong s,jint k){pi_process_key(s,k,0);}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_moveCursor(JNIEnv*,jclass,jlong s,jint direction){return pi_move_pinyin_cursor(s,direction)!=0;}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_atEnd(JNIEnv*,jclass,jlong s){return pi_cursor_at_end(s)!=0;}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_autoPhraseStatus(JNIEnv*e,jclass,jstring input){if(!input)return 0;auto text=utf8(e,input);return pi_auto_phrase_status(text.c_str());}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_learnPhrase(JNIEnv*e,jclass,jstring reading,jstring text){if(!reading||!text)return -1;auto code=utf8(e,reading),word=utf8(e,text);return pi_learn_phrase(code.c_str(),word.c_str());}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_forgetPhrase(JNIEnv*e,jclass,jstring reading,jstring text){if(!reading||!text)return -1;auto code=utf8(e,reading),word=utf8(e,text);return pi_forget_phrase(code.c_str(),word.c_str());}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_candidateTextAllowed(JNIEnv*e,jclass,jstring input){if(!input)return false;auto text=utf8(e,input);return pi_candidate_text_allowed(text.c_str())!=0;}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_candidateReadingAllowed(JNIEnv*e,jclass,jstring input,jstring reading){if(!input)return false;auto text=utf8(e,input),code=utf8(e,reading);return pi_candidate_reading_allowed(text.c_str(),code.c_str())!=0;}
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_draft(JNIEnv*e,jclass,jlong s){auto result=e->NewObjectArray(2,e->FindClass("java/lang/String"),nullptr);std::string values[]={pi_raw_input(s),pi_selected_prefix(s)};for(int i=0;i<2;i++){auto value=str(e,values[i].c_str());e->SetObjectArrayElement(result,i,value);e->DeleteLocalRef(value);}return result;}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_rememberNinePath(JNIEnv*e,jclass,jlong s,jstring raw,jstring prefix,jstring reading){auto r=utf8(e,raw),p=utf8(e,prefix),v=utf8(e,reading);return pi_nine_remember_candidate_path(s,r.c_str(),p.c_str(),v.c_str())!=0;}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_rememberMappedNinePath(JNIEnv*e,jclass,jlong s,jstring raw,jstring prefix,jstring reading,jstring code){auto r=utf8(e,raw),p=utf8(e,prefix),v=utf8(e,reading),c=utf8(e,code);return pi_nine_remember_mapped_candidate_path(s,r.c_str(),p.c_str(),v.c_str(),c.c_str())!=0;}
JNIEXPORT jstring JNICALL Java_live_linghe_privateinput_NativeCore_preferredNineReading(JNIEnv*e,jclass,jlong s){return str(e,pi_nine_preferred_reading(s));}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_rememberVisibleNinePath(JNIEnv*e,jclass,jlong s,jstring raw,jstring prefix,jstring text,jstring reading,jstring code){auto r=utf8(e,raw),p=utf8(e,prefix),t=utf8(e,text),v=utf8(e,reading),c=code?utf8(e,code):std::string();return pi_nine_remember_visible_candidate_path(s,r.c_str(),p.c_str(),t.c_str(),v.c_str(),code?c.c_str():nullptr)!=0;}
JNIEXPORT jstring JNICALL Java_live_linghe_privateinput_NativeCore_preferredNineText(JNIEnv*e,jclass,jlong s){return str(e,pi_nine_preferred_text(s));}
JNIEXPORT jstring JNICALL Java_live_linghe_privateinput_NativeCore_commitPreferredNine(JNIEnv*e,jclass,jlong s,jstring raw,jstring prefix,jstring text,jstring reading){auto r=utf8(e,raw),p=utf8(e,prefix),t=utf8(e,text),v=utf8(e,reading);return str(e,pi_commit_nine_preferred_candidate(s,r.c_str(),p.c_str(),t.c_str(),v.c_str()));}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_selectPreferredNinePrefix(JNIEnv*e,jclass,jlong s,jstring raw,jstring prefix,jstring text,jstring reading){auto r=utf8(e,raw),p=utf8(e,prefix),t=utf8(e,text),v=utf8(e,reading);return pi_select_nine_preferred_prefix(s,r.c_str(),p.c_str(),t.c_str(),v.c_str())!=0;}
JNIEXPORT jintArray JNICALL Java_live_linghe_privateinput_NativeCore_ninePathPriorities(JNIEnv*e,jclass,jlong s,jobjectArray readings){
 if(!readings)return nullptr;const auto count=e->GetArrayLength(readings);if(count>512)return nullptr;
 std::vector<jint> priorities(count,2);
 for(jsize i=0;i<count;++i){auto item=static_cast<jstring>(e->GetObjectArrayElement(readings,i));if(item){auto value=utf8(e,item);priorities[i]=pi_nine_candidate_path_priority(s,value.c_str());e->DeleteLocalRef(item);}}
 auto result=e->NewIntArray(count);if(result&&count)e->SetIntArrayRegion(result,0,count,priorities.data());return result;
}
JNIEXPORT jstring JNICALL Java_live_linghe_privateinput_NativeCore_readableDraft(JNIEnv*e,jclass,jlong s,jstring reading){auto value=utf8(e,reading);return str(e,pi_nine_readable_preedit(s,value.c_str()));}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_hasPending(JNIEnv*,jclass,jlong s){const char* raw=pi_raw_input(s);return raw&&raw[0];}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_clear(JNIEnv*,jclass,jlong s){pi_clear(s);}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_mode(JNIEnv*,jclass,jlong s,jboolean nine,jboolean priv){std::lock_guard<std::recursive_mutex> lock(wrappers);auto it=configs.find(s);if(it==configs.end())return;pi_clear(s);pi_set_private(s,priv);pi_set_nine_key(s,nine);if(it->second.probe){pi_destroy_session(it->second.probe);it->second.probe=0;}it->second.probe_nine=false;it->second.nine=nine;it->second.private_mode=priv;}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_choose(JNIEnv*,jclass,jlong s,jlong i){pi_select_candidate_absolute(s,i);}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_acceptFirst(JNIEnv*,jclass,jlong s){if(!pi_load_candidate_batch(s,0,96))return false;return pi_select_candidate_absolute(s,pi_batch_candidate_index(s,0))!=0;}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_filter(JNIEnv*,jclass,jlong s,jint i){pi_nine_select_syllable(s,i);}
JNIEXPORT void JNICALL Java_live_linghe_privateinput_NativeCore_delete(JNIEnv*,jclass,jlong s){if(pi_nine_can_undo_syllable(s))pi_nine_undo_syllable(s);else pi_process_key(s,0xff08,0);}
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_syllables(JNIEnv*e,jclass,jlong s){size_t n=pi_nine_syllable_count(s);auto result=e->NewObjectArray(n,e->FindClass("java/lang/String"),nullptr);for(size_t i=0;i<n;i++){auto value=str(e,pi_nine_syllable_text(s,i));e->SetObjectArrayElement(result,i,value);e->DeleteLocalRef(value);}return result;}
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_more(JNIEnv*e,jclass,jlong s,jint offset){size_t n=offset<0?0:pi_load_candidate_batch(s,static_cast<size_t>(offset),96);auto strings=e->FindClass("java/lang/String"),rows=e->FindClass("[Ljava/lang/String;");auto out=e->NewObjectArray(n,rows,nullptr);for(size_t i=0;i<n;i++){auto row=e->NewObjectArray(3,strings,nullptr);std::string id=std::to_string(pi_batch_candidate_index(s,i)),text=pi_batch_candidate_text(s,i),reading=pi_batch_candidate_comment(s,i);std::string values[]={id,text,reading};for(int j=0;j<3;j++){auto value=str(e,values[j].c_str());e->SetObjectArrayElement(row,j,value);e->DeleteLocalRef(value);}e->SetObjectArrayElement(out,i,row);e->DeleteLocalRef(row);}return out;}
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_snapshot(JNIEnv*e,jclass,jlong s){size_t n=pi_load_candidate_batch(s,0,96);std::string pre=pi_preedit(s),raw=pi_raw_input(s),commit=pi_take_commit(s);std::string reading=n?pi_batch_candidate_comment(s,0):"";if(*pi_nine_preferred_text(s))reading=pi_nine_preferred_reading(s);std::string display=pi_nine_readable_preedit(s,reading.c_str());
 auto result=e->NewObjectArray(n+1,e->FindClass("[Ljava/lang/String;"),nullptr);auto stringClass=e->FindClass("java/lang/String");
 auto row=[&](size_t index,std::vector<std::string> values){auto arr=e->NewObjectArray(values.size(),stringClass,nullptr);for(size_t i=0;i<values.size();i++){auto v=str(e,values[i].c_str());e->SetObjectArrayElement(arr,i,v);e->DeleteLocalRef(v);}e->SetObjectArrayElement(result,index,arr);e->DeleteLocalRef(arr);};
 auto prefix=pre.substr(0,std::min(pre.size(),pi_preedit_cursor_utf8(s)));auto caretText=str(e,prefix.c_str());auto caret=e->GetStringLength(caretText);e->DeleteLocalRef(caretText);
 row(0,{pre,commit,raw,display,std::string(pi_selected_prefix(s)),std::to_string(caret)});for(size_t i=0;i<n;i++)row(i+1,{std::to_string(pi_batch_candidate_index(s,i)),pi_batch_candidate_text(s,i),pi_batch_candidate_comment(s,i)});return result;
}
// One private query session per live session: never learns or changes live draft.
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_query(JNIEnv*e,jclass,jlong session,jstring input,jboolean nine,jint limit){
 std::lock_guard<std::recursive_mutex> lock(wrappers);
 auto rows=e->FindClass("[Ljava/lang/String;");auto empty=[&]{return e->NewObjectArray(0,rows,nullptr);};
 auto config=configs.find(session);if(config==configs.end()||limit<=0||limit>96)return empty();
 auto value=utf8(e,input);if(!config->second.probe){config->second.probe=pi_create_session();if(!config->second.probe)return empty();pi_set_private(config->second.probe,1);}
 auto probe=config->second.probe;pi_clear(probe);if(config->second.probe_nine!=bool(nine)){if(!pi_set_nine_key(probe,nine))return empty();config->second.probe_nine=nine;}pi_set_ascii_mode(probe,0);
 bool ok=nine?pi_set_prediction_input(probe,value.c_str()):pi_set_pinyin_probe_input(probe,value.c_str());if(!ok)return empty();
 auto count=pi_load_candidate_batch(probe,0,limit);auto out=e->NewObjectArray(count,rows,nullptr);
 for(size_t i=0;i<count;i++){auto row=strings(e,{std::to_string(pi_batch_candidate_index(probe,i)),pi_batch_candidate_text(probe,i),pi_batch_candidate_comment(probe,i)});e->SetObjectArrayElement(out,i,row);e->DeleteLocalRef(row);}return out;
}
// A fresh abbreviation schema probe cannot inherit the exact-repair schema.
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_initials(JNIEnv*e,jclass,jlong session,jstring input,jint limit){
 std::lock_guard<std::recursive_mutex> lock(wrappers);auto rows=e->FindClass("[Ljava/lang/String;");auto empty=[&]{return e->NewObjectArray(0,rows,nullptr);};
 auto value=utf8(e,input);if(!configs.count(session)||limit<=0||limit>64||value.size()<2||value.size()>8||!std::all_of(value.begin(),value.end(),[](char c){return c>='a'&&c<='z';}))return empty();
 auto probe=pi_create_session();if(!probe)return empty();
 if(!pi_set_private(probe,1)||!pi_set_nine_key(probe,0)||!pi_set_ascii_mode(probe,0)){pi_destroy_session(probe);return empty();}
 for(char c:value)pi_process_key(probe,c,0);
 auto count=pi_load_candidate_batch(probe,0,limit);auto out=e->NewObjectArray(count,rows,nullptr);
 for(size_t i=0;i<count;i++){auto row=strings(e,{std::to_string(pi_batch_candidate_index(probe,i)),pi_batch_candidate_text(probe,i),pi_batch_candidate_comment(probe,i)});e->SetObjectArrayElement(out,i,row);e->DeleteLocalRef(row);}pi_destroy_session(probe);return out;
}
JNIEXPORT jlong JNICALL Java_live_linghe_privateinput_NativeCore_editableStart(JNIEnv*,jclass,jlong session){auto value=pi_unselected_input_start(session);return value==SIZE_MAX?-1:static_cast<jlong>(value);}
// Validate in a fresh session, then adopt it only after complete, exact commit.
// Failure leaves the original session, selected prefix and every raw key intact.
JNIEXPORT jobjectArray JNICALL Java_live_linghe_privateinput_NativeCore_commitAlternative(JNIEnv*e,jclass,jlong session,jstring expected,jstring spelling,jstring text,jstring remainder){
 std::lock_guard<std::recursive_mutex> lock(wrappers);
 auto fail=[&]{return strings(e,{});};auto config=configs.find(session);if(config==configs.end())return fail();
 auto raw=utf8(e,expected),canonical=utf8(e,spelling),target=utf8(e,text),suffix=utf8(e,remainder);
 if(raw.empty()||raw!=pi_raw_input(session)||!pi_cursor_at_end(session)||canonical.empty()||canonical.size()>128||target.empty()||target.size()>512||suffix.size()>96)return fail();
 const auto settings=config->second;const std::string selected=pi_selected_prefix(session);
 if(!std::all_of(canonical.begin(),canonical.end(),[](char c){return (c>='a'&&c<='z')||c=='\'';}))return fail();
 if(!std::all_of(suffix.begin(),suffix.end(),[&](char c){return settings.nine?(c>='2'&&c<='9'):(c>='a'&&c<='z');}))return fail();
 auto make=[&](bool private_mode)->PI_Session {
  auto staged=pi_create_session();if(!staged)return 0;
  auto discard=[&]()->PI_Session{pi_destroy_session(staged);return 0;};
  if(!pi_set_private(staged,private_mode)||!pi_set_nine_key(staged,settings.nine)||!pi_set_ascii_mode(staged,0))return discard();
  if(!(settings.nine?pi_stage_nine_input(staged,canonical.c_str()):pi_stage_pinyin_input(staged,canonical.c_str())))return discard();
  size_t absolute=SIZE_MAX;
  for(size_t offset=0;offset<256;offset+=32){auto n=pi_load_candidate_batch(staged,offset,32);for(size_t i=0;i<n;i++)if(target==pi_batch_candidate_text(staged,i)&&normalized(pi_batch_candidate_comment(staged,i))==normalized(canonical)){absolute=pi_batch_candidate_index(staged,i);break;}if(absolute!=SIZE_MAX||n<32)break;}
  if(absolute==SIZE_MAX||!pi_select_candidate_absolute(staged,absolute))return discard();
  const std::string commit=pi_take_commit(staged);
  if(commit!=target||std::string(pi_raw_input(staged))!="")return discard();
  for(char c:suffix)pi_process_key(staged,c,0);
  if(std::string(pi_raw_input(staged))!=suffix||std::string(pi_take_commit(staged))!="")return discard();
  return staged;
 };
 auto staged=make(true);if(!staged)return fail();
 if(!settings.private_mode){pi_destroy_session(staged);staged=make(false);if(!staged)return fail();}
 // Java's worker replaces its handle before the next action. Pending native
 // commit was drained above so manual output cannot be emitted twice.
 configs.emplace(staged,Config{settings.nine,settings.private_mode,0});destroy(session);
 return strings(e,{std::to_string(static_cast<jlong>(staged)),selected+target});
}

JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_closeForCheckpoint(JNIEnv*,jclass,jlong session){
 std::lock_guard<std::recursive_mutex> lock(wrappers);auto config=configs.find(session);if(config==configs.end()||std::string(pi_raw_input(session))!="")return false;
 if(pi_active_session_count()!=size_t(1+(config->second.probe?1:0)))return false;
 destroy(session);return pi_active_session_count()==0;
}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_exportLearning(JNIEnv*e,jclass,jstring file){auto path=utf8(e,file);return path.empty()?-1:pi_export_learning(path.c_str());}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_importLearning(JNIEnv*e,jclass,jstring file){auto path=utf8(e,file);return path.empty()?-1:pi_import_learning(path.c_str());}
JNIEXPORT jint JNICALL Java_live_linghe_privateinput_NativeCore_resetFrequency(JNIEnv*e,jclass,jstring reading,jstring text,jlong count){if(count<0||count>1000000000)return -1;auto code=utf8(e,reading),word=utf8(e,text);return pi_reset_word_frequency(code.c_str(),word.c_str(),count);}
JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_pin(JNIEnv*e,jclass,jstring reading,jstring text,jboolean pinned){auto code=utf8(e,reading),word=utf8(e,text);return pi_set_word_pinned(code.c_str(),word.c_str(),pinned)!=0;}

}

extern "C" JNIEXPORT jboolean JNICALL Java_live_linghe_privateinput_NativeCore_languageInitialize(JNIEnv*e,jclass,jstring folder){auto path=utf8(e,folder);return pi_language_initialize(path.c_str())!=0;}
extern "C" JNIEXPORT jdouble JNICALL Java_live_linghe_privateinput_NativeCore_languageScore(JNIEnv*e,jclass,jstring before,jstring text){auto context=utf8(e,before),value=utf8(e,text);return pi_language_score(context.c_str(),value.c_str());}
