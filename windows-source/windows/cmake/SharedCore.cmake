include_guard(GLOBAL)
# Development consumes the authoritative sibling core, never an algorithm fork.
# Public archives place that same core at the repository root.
get_filename_component(PRIVATE_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
if(EXISTS "${PRIVATE_SOURCE_ROOT}/../private-input/core/include/private_input.h")
  set(PRIVATE_CORE_DEFAULT "${PRIVATE_SOURCE_ROOT}/../private-input/core")
elseif(EXISTS "${PRIVATE_SOURCE_ROOT}/../core/include/private_input.h")
  set(PRIVATE_CORE_DEFAULT "${PRIVATE_SOURCE_ROOT}/../core")
else()
  set(PRIVATE_CORE_DEFAULT "${PRIVATE_SOURCE_ROOT}/core")
endif()
set(PRIVATE_INPUT_CORE_ROOT "${PRIVATE_CORE_DEFAULT}" CACHE PATH "Authoritative shared core source")
get_filename_component(PRIVATE_INPUT_CORE_ROOT "${PRIVATE_INPUT_CORE_ROOT}" REALPATH)
if(NOT EXISTS "${PRIVATE_INPUT_CORE_ROOT}/src/private_input.cpp")
  message(FATAL_ERROR "Provide the authoritative PRIVATE_INPUT_CORE_ROOT")
endif()
message(STATUS "Shared input core: ${PRIVATE_INPUT_CORE_ROOT}")

file(GLOB_RECURSE PRIVATE_CORE_INPUTS CONFIGURE_DEPENDS
  "${PRIVATE_INPUT_CORE_ROOT}/src/*.cpp"
  "${PRIVATE_INPUT_CORE_ROOT}/include/*.h"
  "${PRIVATE_INPUT_CORE_ROOT}/include/*.hpp")
list(SORT PRIVATE_CORE_INPUTS)
set(PRIVATE_CORE_MANIFEST "")
foreach(PRIVATE_CORE_FILE IN LISTS PRIVATE_CORE_INPUTS)
  file(SHA256 "${PRIVATE_CORE_FILE}" PRIVATE_CORE_SHA)
  file(RELATIVE_PATH PRIVATE_CORE_REL "${PRIVATE_INPUT_CORE_ROOT}" "${PRIVATE_CORE_FILE}")
  string(APPEND PRIVATE_CORE_MANIFEST "${PRIVATE_CORE_SHA}  ${PRIVATE_CORE_REL}\n")
endforeach()
file(WRITE "${CMAKE_BINARY_DIR}/shared-core-sha256.txt" "${PRIVATE_CORE_MANIFEST}")
