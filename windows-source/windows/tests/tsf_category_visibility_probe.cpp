// Isolated TSF category-catalog diagnostic. No product profile, COM class,
// activation, input source, text, clipboard, network or security-policy writes.
#include "PrivateInputTSF.h"
#include "TsfBranding.h"
#include <wrl/client.h>
#include <iostream>
#include <string>
#include <vector>
#include <algorithm>
using Microsoft::WRL::ComPtr;
namespace {
constexpr wchar_t FixtureName[]=L"LingheInput.CategoryVisibility060.v1";
std::wstring guidText(REFGUID id){wchar_t value[40]{};StringFromGUID2(id,value,40);return value;}
bool equal(REFGUID a,REFGUID b){return IsEqualGUID(a,b)!=FALSE;}
bool valid(REFGUID id){return !equal(id,GUID_NULL)&&!equal(id,CLSID_PrivateInput)&&!equal(id,GUID_PrivateInputProfile)&&!equal(id,GUID_TFCAT_TIP_KEYBOARD)&&!equal(id,linghe::tsf::SystrayCategory)&&(id.Data3&0xf000)==0x4000&&(id.Data4[0]&0xc0)==0x80;}
struct Observation {HRESULT enumeration=E_UNEXPECTED,next=E_UNEXPECTED;ULONG fetched=0;unsigned total=0;bool found=false;};
Observation observe(ITfCategoryMgr*m,REFGUID key,REFGUID expected,bool reverse){Observation result;ComPtr<IEnumGUID>items;result.enumeration=reverse?m->EnumItemsInCategory(key,&items):m->EnumCategoriesInItem(key,&items);if(FAILED(result.enumeration)||!items)return result;GUID item{};for(unsigned i=0;i<256;++i){result.fetched=0;result.next=items->Next(1,&item,&result.fetched);if(result.next!=S_OK||result.fetched!=1)break;++result.total;if(equal(item,expected))result.found=true;}return result;}
void print(const char*stage,const Observation&o){std::cout<<"{\"stage\":\""<<stage<<"\",\"enumHR\":"<<long(o.enumeration)<<",\"lastNextHR\":"<<long(o.next)<<",\"lastFetched\":"<<o.fetched<<",\"count\":"<<o.total<<",\"found\":"<<(o.found?"true":"false")<<"}\n";}
struct Root {HKEY hive;std::wstring path;};
LONG presence(const Root&r){HKEY key=nullptr;auto error=RegOpenKeyExW(r.hive,r.path.c_str(),0,KEY_READ|KEY_WOW64_64KEY,&key);if(key)RegCloseKey(key);return error;}
std::vector<Root>roots(REFGUID owner,REFGUID category,REFGUID item){std::vector<Root>out;for(auto hive:{HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER}){out.push_back({hive,L"Software\\Microsoft\\CTF\\TIP\\"+guidText(owner)});out.push_back({hive,L"Software\\Microsoft\\CTF\\Category\\Item\\"+guidText(item)});out.push_back({hive,L"Software\\Microsoft\\CTF\\Category\\Category\\"+guidText(category)});}return out;}
void reportRoots(const char*stage,const std::vector<Root>&paths){std::cout<<"{\"stage\":\""<<stage<<"\",\"registryRootStatuses\":[";bool first=true;for(const auto&r:paths){if(!first)std::cout<<',';first=false;std::cout<<presence(r);}std::cout<<"]}\n";}
// Delete only empty containers created beneath the three pre-verified-absent
// synthetic roots. Any nonempty value or unexpected child preserves that root.
bool removeEmpty(const Root&r,REFGUID owner,REFGUID category,REFGUID item,unsigned depth=0){if(depth>6)return false;HKEY key=nullptr;auto error=RegOpenKeyExW(r.hive,r.path.c_str(),0,KEY_READ|KEY_WRITE|KEY_WOW64_64KEY,&key);if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return true;if(error!=ERROR_SUCCESS)return false;DWORD children=0,values=0;if(RegQueryInfoKeyW(key,nullptr,nullptr,nullptr,&children,nullptr,nullptr,&values,nullptr,nullptr,nullptr,nullptr)!=ERROR_SUCCESS||values){RegCloseKey(key);return false;}std::vector<std::wstring>names;for(DWORD i=0;i<children;++i){wchar_t name[256]{};DWORD length=256;if(RegEnumKeyExW(key,i,name,&length,nullptr,nullptr,nullptr,nullptr)!=ERROR_SUCCESS){RegCloseKey(key);return false;}std::wstring value(name,length);if(value!=L"Category"&&value!=L"Item"&&_wcsicmp(value.c_str(),guidText(category).c_str())&&_wcsicmp(value.c_str(),guidText(item).c_str())&&_wcsicmp(value.c_str(),guidText(owner).c_str())){RegCloseKey(key);return false;}names.push_back(value);}RegCloseKey(key);for(const auto&name:names)if(!removeEmpty({r.hive,r.path+L"\\"+name},owner,category,item,depth+1))return false;return RegDeleteKeyExW(r.hive,r.path.c_str(),KEY_WOW64_64KEY,0)==ERROR_SUCCESS;}
void plan(REFGUID owner,REFGUID category,REFGUID item){auto narrow=[](const std::wstring&s){return std::string(s.begin(),s.end());};std::cout<<"{\"fixture\":\""<<narrow(FixtureName)<<"\",\"owner\":\""<<narrow(guidText(owner))<<"\",\"category\":\""<<narrow(guidText(category))<<"\",\"item\":\""<<narrow(guidText(item))<<"\",\"onlyExactTripletMutation\":true,\"productProfileMutation\":false}\n";}
}
int wmain(int argc,wchar_t**argv){
 if(argc!=3&&argc!=10)return 2;if(std::wstring(argv[2])!=FixtureName)return 2;const bool dry=argc==3&&std::wstring(argv[1])==L"--dry-run";const bool write=argc==10&&std::wstring(argv[1])==L"--fixture"&&std::wstring(argv[3])==L"--owner"&&std::wstring(argv[5])==L"--category"&&std::wstring(argv[7])==L"--item"&&std::wstring(argv[9])==L"--confirm-exact-cleanup";if(!dry&&!write)return 2;
 auto initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(initialized))return 3;
 GUID owner{},category{},item{};if(dry){CoCreateGuid(&owner);CoCreateGuid(&category);CoCreateGuid(&item);}else if(FAILED(CLSIDFromString(argv[4],&owner))||FAILED(CLSIDFromString(argv[6],&category))||FAILED(CLSIDFromString(argv[8],&item))){CoUninitialize();return 2;}
 if(!valid(owner)||!valid(category)||!valid(item)||equal(owner,item)||equal(owner,category)||equal(item,category)){CoUninitialize();return 2;}plan(owner,category,item);if(dry){std::cout<<"{\"dryRun\":true,\"registryWrites\":false,\"copyExactPlanGUIDsForFixtureRun\":true}\n";CoUninitialize();return 0;}
 const auto paths=roots(owner,category,item);for(const auto&r:paths){auto error=presence(r);if(error!=ERROR_FILE_NOT_FOUND&&error!=ERROR_PATH_NOT_FOUND){reportRoots("preexisting-or-unreadable-refused",paths);CoUninitialize();return 4;}}
 for(auto hive:{HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER})for(const auto&prefix:{L"Software\\Classes\\CLSID\\",L"Software\\Microsoft\\CTF\\TIP\\"})for(const auto&id:{owner,category,item}){auto error=presence({hive,std::wstring(prefix)+guidText(id)});if(error!=ERROR_FILE_NOT_FOUND&&error!=ERROR_PATH_NOT_FOUND){CoUninitialize();return 4;}}
 bool attempted=false,clean=true;HRESULT mutation=E_UNEXPECTED,cleanup=E_UNEXPECTED;int result=5;
 {
 ComPtr<ITfCategoryMgr>manager;auto created=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager));if(SUCCEEDED(created)){
 print("before-same-item",observe(manager.Get(),item,category,false));print("before-same-category",observe(manager.Get(),category,item,true));reportRoots("before-register",paths);
 attempted=true;mutation=manager->RegisterCategory(owner,category,item);std::cout<<"{\"stage\":\"register-category\",\"hr\":"<<long(mutation)<<"}\n";
 if(SUCCEEDED(mutation)){print("after-same-item",observe(manager.Get(),item,category,false));print("after-same-category",observe(manager.Get(),category,item,true));reportRoots("after-register",paths);
 ComPtr<ITfCategoryMgr>fresh;auto hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&fresh));if(SUCCEEDED(hr)){print("after-fresh-item",observe(fresh.Get(),item,category,false));print("after-fresh-category",observe(fresh.Get(),category,item,true));}else std::cout<<"{\"stage\":\"fresh-manager\",\"hr\":"<<long(hr)<<"}\n";
 }
 if(attempted){cleanup=manager->UnregisterCategory(owner,category,item);std::cout<<"{\"stage\":\"unregister-category\",\"hr\":"<<long(cleanup)<<"}\n";for(const auto&r:paths)clean=removeEmpty(r,owner,category,item)&&clean;reportRoots("after-exact-cleanup",paths);print("after-unregister-same-item",observe(manager.Get(),item,category,false));for(const auto&r:paths){auto error=presence(r);clean=clean&&(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND);}}
 result=SUCCEEDED(mutation)&&SUCCEEDED(cleanup)&&clean?0:5;
 }else std::cout<<"{\"stage\":\"create-manager\",\"hr\":"<<long(created)<<"}\n";
 }
 CoUninitialize();std::cout<<"{\"fixtureComplete\":"<<(result==0?"true":"false")<<",\"mutationAttempted\":"<<(attempted?"true":"false")<<",\"allSyntheticRootsAbsent\":"<<(clean?"true":"false")<<",\"productProfileTouched\":false}\n";return result;
}
