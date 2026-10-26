#pragma once
namespace private_input {
enum class PhraseFieldScope {unknown,normal,privateField,password};
// Rime's private/stateless option is deliberately not a privacy signal here:
// production Windows keeps it on because the Worker owns persistent learning.
inline bool phraseNoticeAllowed(const void*fixtureEnginePaths,PhraseFieldScope field,bool disabled,bool secure,bool localLearningEnabled){
 return fixtureEnginePaths==nullptr&&field==PhraseFieldScope::normal&&!disabled&&!secure&&localLearningEnabled;
}
}
