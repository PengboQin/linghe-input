#pragma once
#include <cstddef>

namespace private_input {
// Only an explicit host declaration makes an address/code field literal. A
// failed property lookup is not evidence that a field is safe or technical.
enum class PhysicalFieldScope { unknown, ordinary, url, email, digits, privateField, password };
inline bool literalTechnicalScope(const PhysicalFieldScope *scopes, std::size_t count) {
  if (!scopes || !count || count > 128) return false;
  bool literal = false;
  for (std::size_t i = 0; i < count; ++i) {
    if (scopes[i] == PhysicalFieldScope::privateField || scopes[i] == PhysicalFieldScope::password ||
        scopes[i] == PhysicalFieldScope::unknown) return false;
    literal = literal || scopes[i] == PhysicalFieldScope::url || scopes[i] == PhysicalFieldScope::email ||
              scopes[i] == PhysicalFieldScope::digits;
  }
  return literal;
}
}
