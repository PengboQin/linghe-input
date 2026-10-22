#include "../installer/InstallReview.h"
#include "../installer/PayloadManifest.h"
#include <cstdlib>
#include <iostream>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))std::abort();}while(false)
int main(){using namespace linghe::installer;
 CHECK(reviewNeeded(false,false));CHECK(!reviewNeeded(true,false));CHECK(!reviewNeeded(false,true));
 auto review=installReview(L"0.5.5-win1",L"C:\\Program Files\\LingheInput",L"0.5.4-win1",false,false);
 CHECK(review.instruction.find(L"0.5.5-win1")!=std::wstring::npos);CHECK(review.start==L"开始安装");CHECK(review.body.find(L"C:\\Program Files\\LingheInput")!=std::wstring::npos);CHECK(review.body.find(L"0.5.4-win1")!=std::wstring::npos);CHECK(review.body.find(L"保留个人词库")!=std::wstring::npos);
 CHECK(installReview(L"v",L"root",L"",true,false).start==L"开始卸载");CHECK(installReview(L"v",L"root",L"",false,true).start==L"开始修复");
 CHECK(recognizedSetupHash("4a09a75b70eb6dbf309afd8809669df04d11dcef427d3d8b55e54598aeb0b120",std::string(64,'b')));CHECK(!recognizedSetupHash(std::string(64,'c'),std::string(64,'b')));
 std::cout<<"PASS "<<checks<<" native-review presentation and exact054 ownership checks; no writes/UI/system operations\n";
}
