// Independent synthetic category diagnostic: owner == item, category distinct.
// Never registers a product profile/COM class or changes input/security settings.
#include "PrivateInputTSF.h"
#include "TsfBranding.h"
#include <wrl/client.h>
#include <iostream>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace {
constexpr wchar_t FixtureName[] = L"LingheInput.CategoryIdentity061.v2";
bool equal(REFGUID a, REFGUID b) { return IsEqualGUID(a, b) != FALSE; }
std::wstring guidText(REFGUID id) {
    wchar_t value[40]{}; StringFromGUID2(id, value, 40); return value;
}
std::string ascii(const std::wstring& value) { return {value.begin(), value.end()}; }
bool parseGuid(const wchar_t* text, GUID& result) {
    const std::wstring value(text);
    if (value.size() != 38 || value.front() != L'{' || value.back() != L'}') return false;
    for (size_t i = 1; i < 37; ++i) {
        if (i == 9 || i == 14 || i == 19 || i == 24) {
            if (value[i] != L'-') return false;
        } else if (!((value[i] >= L'0' && value[i] <= L'9') ||
            (value[i] >= L'a' && value[i] <= L'f') || (value[i] >= L'A' && value[i] <= L'F'))) return false;
    }
    return SUCCEEDED(CLSIDFromString(value.c_str(), &result));
}
bool valid(REFGUID id) {
    return !equal(id, GUID_NULL) && !equal(id, CLSID_PrivateInput) &&
        !equal(id, GUID_PrivateInputProfile) && !equal(id, GUID_TFCAT_TIP_KEYBOARD) &&
        !equal(id, GUID_TFCAT_TIP_SPEECH) && !equal(id, GUID_TFCAT_TIP_HANDWRITING) &&
        !equal(id, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER) &&
        !equal(id, linghe::tsf::SystrayCategory) &&
        (id.Data3 & 0xf000) == 0x4000 && (id.Data4[0] & 0xc0) == 0x80;
}
struct NextResult { HRESULT hr; ULONG fetched; };
struct Observation {
    HRESULT enumeration = E_UNEXPECTED;
    unsigned total = 0;
    bool found = false, completed = false, limitReached = false;
    std::vector<NextResult> next;
};
Observation observe(ITfCategoryMgr* manager, REFGUID key, REFGUID expected, bool reverse) {
    Observation result; ComPtr<IEnumGUID> items;
    result.enumeration = reverse ? manager->EnumItemsInCategory(key, &items) :
        manager->EnumCategoriesInItem(key, &items);
    if (FAILED(result.enumeration) || !items) return result;
    for (unsigned i = 0; i < 256; ++i) {
        GUID item{}; ULONG fetched = 0;
        HRESULT hr = items->Next(1, &item, &fetched);
        result.next.push_back({hr, fetched});
        if (hr == S_FALSE && fetched == 0) { result.completed = true; return result; }
        if (hr != S_OK || fetched != 1) return result;
        ++result.total;
        if (equal(item, expected)) result.found = true;
    }
    result.limitReached = true;
    return result;
}
void print(const std::string& stage, const Observation& value) {
    std::cout << "{\"stage\":\"" << stage << "\",\"enumHR\":" << long(value.enumeration)
        << ",\"count\":" << value.total << ",\"found\":" << (value.found ? "true" : "false")
        << ",\"completed\":" << (value.completed ? "true" : "false")
        << ",\"limitReached\":" << (value.limitReached ? "true" : "false") << ",\"next\":[";
    bool first = true;
    for (const auto& next : value.next) {
        if (!first) std::cout << ','; first = false;
        std::cout << "{\"hr\":" << long(next.hr) << ",\"fetched\":" << next.fetched << '}';
    }
    std::cout << "]}\n";
}
bool observeBoth(const std::string& stage, ITfCategoryMgr* manager, REFGUID owner, REFGUID category) {
    auto forward = observe(manager, owner, category, false);
    auto reverse = observe(manager, category, owner, true);
    print(stage + "-item", forward); print(stage + "-category", reverse);
    return forward.completed && forward.found && reverse.completed && reverse.found;
}
struct Root { HKEY hive; std::wstring path; const char* kind; };
bool absent(LONG status) { return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND; }
LONG presence(const Root& root) {
    HKEY key = nullptr;
    LONG status = RegOpenKeyExW(root.hive, root.path.c_str(), 0, KEY_READ | KEY_WOW64_64KEY, &key);
    if (key) RegCloseKey(key); return status;
}
std::vector<Root> roots(REFGUID owner, REFGUID category) {
    std::vector<Root> result;
    for (auto hive : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
        result.push_back({hive, L"Software\\Microsoft\\CTF\\TIP\\" + guidText(owner), "ownerTIP"});
        result.push_back({hive, L"Software\\Microsoft\\CTF\\Category\\Item\\" + guidText(owner), "item"});
        result.push_back({hive, L"Software\\Microsoft\\CTF\\Category\\Category\\" + guidText(category), "category"});
    }
    return result;
}
bool reportRoots(const char* stage, const std::vector<Root>& paths) {
    bool first = true, allAbsent = true;
    std::cout << "{\"stage\":\"" << stage << "\",\"registryRoots\":[";
    for (const auto& root : paths) {
        LONG status = presence(root); allAbsent = allAbsent && absent(status);
        if (!first) std::cout << ','; first = false;
        std::cout << "{\"hive\":\"" << (root.hive == HKEY_LOCAL_MACHINE ? "HKLM" : "HKCU")
            << "\",\"kind\":\"" << root.kind << "\",\"status\":" << status << '}';
    }
    std::cout << "],\"allAbsent\":" << (allAbsent ? "true" : "false") << "}\n";
    return allAbsent;
}
// Only the six roots proven absent before mutation may reach this function.
// Every descendant name must match this exact synthetic triplet's whitelist;
// values, unreadable keys, unexpected names and excessive depth stop deletion.
// There is no RegDeleteTree, value deletion or deletion of shared parent roots.
bool removeEmpty(const Root& root, REFGUID owner, REFGUID category, unsigned depth = 0) {
    if (depth > 6) return false;
    HKEY key = nullptr;
    LONG status = RegOpenKeyExW(root.hive, root.path.c_str(), 0,
        KEY_READ | KEY_WRITE | KEY_WOW64_64KEY, &key);
    if (absent(status)) return true;
    if (status != ERROR_SUCCESS) return false;
    DWORD children = 0, values = 0;
    if (RegQueryInfoKeyW(key, nullptr, nullptr, nullptr, &children, nullptr, nullptr,
        &values, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS || values) {
        RegCloseKey(key); return false;
    }
    std::vector<std::wstring> names;
    for (DWORD i = 0; i < children; ++i) {
        wchar_t name[256]{}; DWORD length = 256;
        if (RegEnumKeyExW(key, i, name, &length, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
            RegCloseKey(key); return false;
        }
        std::wstring child(name, length);
        if (child != L"Category" && child != L"Item" &&
            _wcsicmp(child.c_str(), guidText(category).c_str()) &&
            _wcsicmp(child.c_str(), guidText(owner).c_str())) {
            RegCloseKey(key); return false;
        }
        names.push_back(child);
    }
    RegCloseKey(key);
    for (const auto& name : names)
        if (!removeEmpty({root.hive, root.path + L"\\" + name, root.kind}, owner, category, depth + 1))
            return false;
    // RegDeleteKeyExW can delete values; recheck that this exact key is empty.
    key = nullptr;
    status = RegOpenKeyExW(root.hive, root.path.c_str(), 0, KEY_READ | KEY_WOW64_64KEY, &key);
    if (absent(status)) return true;
    if (status != ERROR_SUCCESS) return false;
    children = values = 0;
    status = RegQueryInfoKeyW(key, nullptr, nullptr, nullptr, &children, nullptr, nullptr,
        &values, nullptr, nullptr, nullptr, nullptr);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS || children || values) return false;
    return RegDeleteKeyExW(root.hive, root.path.c_str(), KEY_WOW64_64KEY, 0) == ERROR_SUCCESS;
}
void plan(REFGUID owner, REFGUID category) {
    std::cout << "{\"fixture\":\"" << ascii(FixtureName) << "\",\"owner\":\"" << ascii(guidText(owner))
        << "\",\"category\":\"" << ascii(guidText(category)) << "\",\"item\":\"" << ascii(guidText(owner))
        << "\",\"ownerEqualsItem\":true,\"onlyExactTripletMutation\":true,\"productProfileMutation\":false}\n";
}
HRESULT createManager(ComPtr<ITfCategoryMgr>& manager, const std::string& stage) {
    HRESULT hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager));
    std::cout << "{\"stage\":\"" << stage << "\",\"hr\":" << long(hr) << "}\n"; return hr;
}
bool freshObservation(const std::string& stage, REFGUID owner, REFGUID category) {
    ComPtr<ITfCategoryMgr> fresh;
    if (FAILED(createManager(fresh, stage + "-manager"))) return false;
    return observeBoth(stage, fresh.Get(), owner, category);
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc != 3 && argc != 10) return 2;
    if (std::wstring(argv[2]) != FixtureName) return 2;
    const bool dry = argc == 3 && std::wstring(argv[1]) == L"--dry-run";
    const bool write = argc == 10 && std::wstring(argv[1]) == L"--fixture" &&
        std::wstring(argv[3]) == L"--owner" && std::wstring(argv[5]) == L"--category" &&
        std::wstring(argv[7]) == L"--item" && std::wstring(argv[9]) == L"--confirm-exact-cleanup";
    if (!dry && !write) return 2;
    GUID owner{}, category{}, item{};
    if (dry) {
        if (FAILED(CoCreateGuid(&owner)) || FAILED(CoCreateGuid(&category))) return 3;
        item = owner;
    } else if (!parseGuid(argv[4], owner) || !parseGuid(argv[6], category) || !parseGuid(argv[8], item)) return 2;
    if (!valid(owner) || !valid(category) || !valid(item) || !equal(owner, item) || equal(owner, category)) return 2;
    plan(owner, category);
    if (dry) {
        std::cout << "{\"dryRun\":true,\"registryWrites\":false,\"copyExactPlanGUIDsForFixtureRun\":true}\n";
        return 0;
    }
    const auto paths = roots(owner, category);
    if (!reportRoots("preflight-six-roots", paths)) return 4;
    for (auto hive : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER})
        for (const auto& prefix : {L"Software\\Classes\\CLSID\\", L"Software\\Microsoft\\CTF\\TIP\\"})
            for (const auto& id : {owner, category}) {
                LONG status = presence({hive, std::wstring(prefix) + guidText(id), "identityGuard"});
                if (!absent(status)) {
                    std::cout << "{\"stage\":\"preexisting-or-unreadable-identity-refused\",\"status\":" << status << "}\n";
                    return 4;
                }
            }
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(initialized)) return 3;
    int result = 5;
    {
        ComPtr<ITfCategoryMgr> manager;
        if (SUCCEEDED(createManager(manager, "create-same-manager"))) {
            observeBoth("before-same", manager.Get(), owner, category);
            freshObservation("before-fresh", owner, category);
            // Recheck immediately before the only category registration call.
            if (reportRoots("before-register", paths)) {
                HRESULT registration = manager->RegisterCategory(owner, category, item);
                std::cout << "{\"stage\":\"register-category\",\"hr\":" << long(registration) << "}\n";
                reportRoots("after-register", paths);
                bool sameVisible = observeBoth("after-same", manager.Get(), owner, category);
                bool freshVisible = freshObservation("after-fresh", owner, category);
                // Always attempt exact unregister after RegisterCategory, even on failure.
                HRESULT cleanup = manager->UnregisterCategory(owner, category, item);
                std::cout << "{\"stage\":\"unregister-category\",\"hr\":" << long(cleanup) << "}\n";
                reportRoots("after-unregister-before-empty-cleanup", paths);
                bool emptyCleanup = true;
                for (const auto& root : paths) {
                    bool removed = removeEmpty(root, owner, category);
                    emptyCleanup = removed && emptyCleanup;
                    std::cout << "{\"stage\":\"empty-root-cleanup\",\"hive\":\""
                        << (root.hive == HKEY_LOCAL_MACHINE ? "HKLM" : "HKCU") << "\",\"kind\":\""
                        << root.kind << "\",\"complete\":" << (removed ? "true" : "false") << "}\n";
                }
                bool rootsAbsent = reportRoots("after-exact-cleanup", paths);
                observeBoth("cleanup-same", manager.Get(), owner, category);
                freshObservation("cleanup-fresh", owner, category);
                bool clean = SUCCEEDED(cleanup) && emptyCleanup && rootsAbsent;
                bool matched = SUCCEEDED(registration) && sameVisible && freshVisible;
                result = !clean || FAILED(registration) ? 5 : (matched ? 0 : 6);
                std::cout << "{\"registrationSucceeded\":" << (SUCCEEDED(registration) ? "true" : "false")
                    << ",\"sameManagerEnumerationMatched\":" << (sameVisible ? "true" : "false")
                    << ",\"freshManagerEnumerationMatched\":" << (freshVisible ? "true" : "false")
                    << ",\"cleanupComplete\":" << (clean ? "true" : "false")
                    << ",\"allSyntheticRootsAbsent\":" << (rootsAbsent ? "true" : "false")
                    << ",\"productProfileTouched\":false,\"exitCode\":" << result << "}\n";
            } else result = 4;
        }
    }
    CoUninitialize(); return result;
}
