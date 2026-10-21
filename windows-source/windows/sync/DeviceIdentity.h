#pragma once
#ifdef _WIN32
#include <windows.h>
#endif

#include <array>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
namespace private_input {
void eraseIdentityMemory(void*,size_t)noexcept;
struct IdentityError:std::runtime_error { uint32_t code; IdentityError(const char* message,uint32_t value=0):std::runtime_error(message),code(value){} };
struct DeviceIdentity {
 std::array<unsigned char,16> device{},owner{};
 std::array<unsigned char,32> signingSeed{},ownerSeed{},exchangeSecret{},storageKey{};
 uint64_t reservedSequence=0;
 ~DeviceIdentity(){eraseIdentityMemory(signingSeed.data(),32);eraseIdentityMemory(ownerSeed.data(),32);eraseIdentityMemory(exchangeSecret.data(),32);eraseIdentityMemory(storageKey.data(),32);}
};
// Current-user DPAPI and owner-only ACL. No product registration or cached counter.
class DeviceIdentityVault {
 std::filesystem::path root_;
 DeviceIdentity readLocked();
 void saveLocked(const DeviceIdentity& identity,bool create);
 public:
 explicit DeviceIdentityVault(std::filesystem::path root);
 DeviceIdentity create();
 DeviceIdentity load();
 DeviceIdentity resetForDeparture();
 DeviceIdentity reserveSequence();
};
}
