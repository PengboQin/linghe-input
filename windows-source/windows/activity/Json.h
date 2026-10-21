#pragma once
#include <cstdint>
#include <map>
#include <vector>
#include <string>
#include <string_view>
#include <stdexcept>
namespace private_input::activity {
struct JsonError:std::runtime_error {using std::runtime_error::runtime_error;};
struct Json {
 enum class Kind {null,boolean,number,string,array,object};
 Kind kind=Kind::null; bool flag=false; uint64_t integer=0; std::string text; std::vector<Json> items; std::map<std::string,Json> fields;
 Json()=default; Json(bool x):kind(Kind::boolean),flag(x){} Json(uint64_t x):kind(Kind::number),integer(x){} Json(int x):Json(uint64_t(x)){if(x<0)throw JsonError("negative integer");} Json(const char*x):kind(Kind::string),text(x){} Json(std::string x):kind(Kind::string),text(std::move(x)){}
 static Json object(std::initializer_list<std::pair<const std::string,Json>> x={}){Json j;j.kind=Kind::object;j.fields=x;return j;}
 static Json array(std::vector<Json> x={}){Json j;j.kind=Kind::array;j.items=std::move(x);return j;}
 const Json& at(const std::string& key)const{if(kind!=Kind::object)throw JsonError("object required");auto p=fields.find(key);if(p==fields.end())throw JsonError("missing field");return p->second;}
 Json& operator[](const std::string& key){if(kind!=Kind::object)throw JsonError("object required");return fields[key];}
 bool has(const std::string&key)const{return kind==Kind::object&&fields.count(key);}
 std::string str()const{if(kind!=Kind::string)throw JsonError("string required");return text;}
 uint64_t num()const{if(kind!=Kind::number)throw JsonError("integer required");return integer;}
 bool boolean()const{if(kind!=Kind::boolean)throw JsonError("boolean required");return flag;}
 static Json parse(std::string_view,size_t maxBytes=4194304,size_t maxDepth=16,size_t maxNodes=65536);
 std::string dump()const;
};
void require(bool,const char*);
void validateUtf8(std::string_view);
}
