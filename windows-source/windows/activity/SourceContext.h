#pragma once
#include "Json.h"
#include "CaptureWire.h"
#include <string>
namespace private_input::activity {
struct SourceContext {
 std::string identifier,name,identityStatus="unavailable",methodVersion="unavailable",methodBuild="unavailable",fieldType="unavailable",returnKey="unavailable",layout="unavailable",provenance="unavailable",captureComponent="unavailable";
};
inline SourceContext sourceContextFromWire(const CaptureContextWire&w){require(validCaptureContextWire(w),"capture context wire");SourceContext s;s.identifier=captureWireString(w.app,w.appBytes);s.name=captureWireString(w.name,w.nameBytes);s.methodVersion=captureWireString(w.version,w.versionBytes);s.methodBuild=captureWireString(w.build,w.buildBytes);validateUtf8(s.identifier);validateUtf8(s.name);validateUtf8(s.methodVersion);validateUtf8(s.methodBuild);s.fieldType=w.field==1?"normal":w.field==2?"email":w.field==3?"url":w.field==4?"number":w.field==5?"phone":w.field==6?"search":"unavailable";s.layout=w.layout==1?"pinyin_qwerty":w.layout==2?"english_qwerty":"unavailable";s.captureComponent="input_method";s.provenance=w.provenance==1?"input_host":w.provenance==2?"clipboard_owner":"unavailable";return s;}
inline bool safeSourceLabel(const std::string&s,size_t limit){if(s.empty()||s.size()>limit||s.find_first_of("\\/:\r\n\t")!=std::string::npos)return false;for(unsigned char c:s)if(c<32||c==127)return false;try{validateUtf8(s);}catch(...){return false;}return true;}
inline Json sourceContextJSON(const SourceContext&s){
 const bool id=safeSourceLabel(s.identifier,191),name=id&&safeSourceLabel(s.name,255);
 return Json::object({{"platform","windows"},{"source_app_id",id?Json(s.identifier):Json()},{"capture_component",s.captureComponent=="input_method"||s.captureComponent=="clipboard_observer"?s.captureComponent:"unavailable"},{"source_app_name",name?Json(s.name):Json("unavailable")},{"app_identity_status",name?"available":id?"identifier_only":"unavailable"},{"input_method_version",safeSourceLabel(s.methodVersion,23)?s.methodVersion:"unavailable"},{"input_method_build",safeSourceLabel(s.methodBuild,15)?s.methodBuild:"unavailable"},{"field_type",s.fieldType=="normal"||s.fieldType=="email"||s.fieldType=="url"||s.fieldType=="number"||s.fieldType=="phone"||s.fieldType=="search"?s.fieldType:"unavailable"},{"return_key","unavailable"},{"layout",s.layout=="pinyin_qwerty"||s.layout=="english_qwerty"?s.layout:"unavailable"},{"source_app_provenance",s.provenance=="input_host"||s.provenance=="clipboard_owner"?s.provenance:"unavailable"}});
}
}
