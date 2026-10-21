cmake_minimum_required(VERSION 3.24)
project(LingheGroupClientFixture LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(PRIVATE_SODIUM_PREFIX "" CACHE PATH "Existing same-architecture libsodium; never fetched automatically")
find_path(SODIUM_INCLUDE sodium.h PATHS "${PRIVATE_SODIUM_PREFIX}/include" NO_DEFAULT_PATH REQUIRED)
find_library(SODIUM_LIBRARY NAMES sodium libsodium PATHS "${PRIVATE_SODIUM_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
find_package(Python3 COMPONENTS Interpreter REQUIRED)
get_filename_component(PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(ACTIVITY "${PROJECT_ROOT}/windows/activity")
set(SYNC "${PROJECT_ROOT}/windows/sync")
add_executable(LingheGroupClientFixture group_client_host.cpp
 "${ACTIVITY}/GroupClient.cpp" "${ACTIVITY}/Json.cpp" "${ACTIVITY}/ArchiveCore.cpp" "${ACTIVITY}/ArchiveQueue.cpp"
 "${ACTIVITY}/GroupProtocol.cpp" "${ACTIVITY}/PairAdmission.cpp" "${ACTIVITY}/ContentModel.cpp" "${ACTIVITY}/ContentStore.cpp"
 "${ACTIVITY}/LegacyLearning.cpp" "${ACTIVITY}/RecentModel.cpp" "${ACTIVITY}/RecentProtocol.cpp"
 "${SYNC}/SecureProtocol.cpp" "${SYNC}/Membership.cpp" "${SYNC}/MembershipWire.cpp")
target_include_directories(LingheGroupClientFixture PRIVATE "${SODIUM_INCLUDE}")
target_compile_definitions(LingheGroupClientFixture PRIVATE SODIUM_STATIC)
target_link_libraries(LingheGroupClientFixture PRIVATE "${SODIUM_LIBRARY}" ${CMAKE_DL_LIBS})
if(WIN32)
 target_link_libraries(LingheGroupClientFixture PRIVATE advapi32 bcrypt)
endif()
enable_testing()
add_test(NAME GroupClientQueueRecovery COMMAND LingheGroupClientFixture)
set_tests_properties(GroupClientQueueRecovery PROPERTIES WORKING_DIRECTORY "${PROJECT_ROOT}"
 ENVIRONMENT "PRIVATE_INPUT_FIXTURE_PYTHON=${Python3_EXECUTABLE}" TIMEOUT 300)

# 044 isolated policies plus the actual GroupClient publication/receive bridge.
add_executable(LingheClipboardContextFixture clipboard_context.cpp
 "${ACTIVITY}/AutomaticClipboard.cpp" "${ACTIVITY}/Json.cpp" "${ACTIVITY}/ArchiveCore.cpp")
target_include_directories(LingheClipboardContextFixture PRIVATE "${SODIUM_INCLUDE}")
target_compile_definitions(LingheClipboardContextFixture PRIVATE SODIUM_STATIC)
target_link_libraries(LingheClipboardContextFixture PRIVATE "${SODIUM_LIBRARY}")
if(WIN32)
 target_link_libraries(LingheClipboardContextFixture PRIVATE user32)
endif()
add_test(NAME ClipboardContextPolicy COMMAND LingheClipboardContextFixture)
add_test(NAME GroupClientAutomaticClipboard COMMAND LingheGroupClientFixture --clipboard-only)
set_tests_properties(GroupClientAutomaticClipboard PROPERTIES WORKING_DIRECTORY "${PROJECT_ROOT}"
 ENVIRONMENT "PRIVATE_INPUT_FIXTURE_PYTHON=${Python3_EXECUTABLE}" TIMEOUT 90)

# 045 no real clipboard or installed TSF is opened by these fixtures.
add_executable(LingheClipboardCandidateFixture ../clipboard_candidate.cpp)
target_include_directories(LingheClipboardCandidateFixture PRIVATE "${PROJECT_ROOT}/windows/src")
add_test(NAME ClipboardCandidatePolicy COMMAND LingheClipboardCandidateFixture)
add_executable(LingheClipboardCandidateArchiveFixture clipboard_candidate_archive.cpp
 "${ACTIVITY}/Json.cpp" "${ACTIVITY}/ArchiveCore.cpp" "${ACTIVITY}/ArchiveQueue.cpp")
target_include_directories(LingheClipboardCandidateArchiveFixture PRIVATE "${SODIUM_INCLUDE}")
target_compile_definitions(LingheClipboardCandidateArchiveFixture PRIVATE SODIUM_STATIC)
target_link_libraries(LingheClipboardCandidateArchiveFixture PRIVATE "${SODIUM_LIBRARY}" ${CMAKE_DL_LIBS})
add_test(NAME ClipboardCandidateArchive COMMAND LingheClipboardCandidateArchiveFixture "${CMAKE_CURRENT_BINARY_DIR}/clipboard-candidate-disposable.sqlite")

add_executable(LingheClipboardReadSafetyFixture clipboard_read_safety.cpp
 "${ACTIVITY}/AutomaticClipboard.cpp" "${ACTIVITY}/Json.cpp" "${ACTIVITY}/ArchiveCore.cpp")
target_include_directories(LingheClipboardReadSafetyFixture PRIVATE "${SODIUM_INCLUDE}")
target_compile_definitions(LingheClipboardReadSafetyFixture PRIVATE SODIUM_STATIC)
target_link_libraries(LingheClipboardReadSafetyFixture PRIVATE "${SODIUM_LIBRARY}")
add_test(NAME ClipboardReadSafety COMMAND LingheClipboardReadSafetyFixture)
