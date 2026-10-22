#pragma once
#include "UpgradeState.h"
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>
namespace linghe::installer {
// Read-only presentation policy: never repairs, changes trust or opens UI itself.
inline std::wstring upgradeReason(const std::string&stage){
 const auto is=[&](UpgradeState state){return stage=="mixed-installation-"+std::to_string(static_cast<unsigned>(state));};
 if(is(UpgradeState::RegistrationArpMismatch))return L"输入服务注册与卸载登记不一致。";
 if(is(UpgradeState::ArpVersionMismatch))return L"输入服务与卸载程序指向不同版本。";
 if(is(UpgradeState::WorkerMismatch))return L"正在运行的后台与已登记版本不一致。";
 if(is(UpgradeState::StartupMismatch))return L"登录启动项与已登记的后台版本不一致。";
 return {};
}
inline std::wstring failureFeedback(int code,const std::string&stage,uint32_t hr,bool committed,
                                   const std::wstring&receipt,bool receiptSaved,const std::wstring&installer){
 auto reason=upgradeReason(stage);std::wstring text;
 if(code==42&&!reason.empty()&&!committed){text=reason+L"\n当前安装已停止，现有后台保持运行。\n可先使用此安装包的受支持修复流程，再运行普通安装：\n\""+installer+L"\" --repair";}
 else if(code==40)text=L"输入服务已停用，文件清理尚未完成。\n关闭使用灵鹤的窗口后，用同一安装包的 --uninstall 重试。占用文件、未知文件及卸载入口已保留。";
 else if(code==21)text=L"操作未完成，恢复原注册时遇到错误。请保留安装文件和回执。";
 else if(code==740)text=L"未获得安装所需的管理员授权。请从当前登录用户重新运行安装包，并完成系统授权。";
 else text=committed?L"输入服务操作已提交，但后续步骤未完成。请根据回执中的阶段检查后重试。":L"安装操作未完成，请根据下面的阶段和错误码检查。";
 std::wostringstream detail;detail<<L"\n\n阶段："<<std::wstring(stage.begin(),stage.end())<<L"\n错误码："<<code<<L" / 0x"<<std::uppercase<<std::hex<<std::setw(8)<<std::setfill(L'0')<<hr;
 detail<<L"\n"<<(receiptSaved?L"安装回执：":L"回执未能写入，预定位置：")<<receipt<<L"\n个人词库与配置未操作。";
 return text+detail.str();
}
}
