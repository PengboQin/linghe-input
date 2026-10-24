#include "TechnicalInputScope.h"
#include <cassert>
#include <iostream>
#include <initializer_list>
using Scope=private_input::PhysicalFieldScope;
int main(){
  unsigned checks=0;
  auto check=[&](std::initializer_list<Scope>scopes,bool expected){
    assert(private_input::literalTechnicalScope(scopes.begin(),scopes.size())==expected);++checks;
  };
  check({},false);check({Scope::unknown},false);check({Scope::ordinary},false);
  for(auto literal:{Scope::url,Scope::email,Scope::digits}){
    check({literal},true);check({Scope::ordinary,literal},true);check({literal,Scope::ordinary},true);
    for(auto blocked:{Scope::password,Scope::privateField,Scope::unknown}){
      check({literal,blocked},false);check({blocked,literal},false);
    }
  }
  check({Scope::url,Scope::email,Scope::digits},true);
  Scope oversized[129]{};assert(!private_input::literalTechnicalScope(oversized,129));++checks;
  assert(!private_input::literalTechnicalScope(nullptr,1));++checks;
  std::cout<<"{\"passed\":true,\"assertions\":"<<checks<<",\"unknownAndSensitiveDoNotOptIn\":true}\n";
}
