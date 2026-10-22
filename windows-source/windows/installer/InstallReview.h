#pragma once
#include <string>
namespace linghe::installer {
struct InstallReview {std::wstring title,instruction,body,start;};
inline bool reviewNeeded(bool quiet,bool confirmed){return !quiet&&!confirmed;}
inline InstallReview installReview(const std::wstring&version,const std::wstring&root,const std::wstring&current,bool remove,bool repair){
 InstallReview r;r.title=L"灵鹤输入法";r.instruction=repair?L"修复输入法登记":remove?L"卸载灵鹤输入法":L"安装灵鹤输入法 "+version;
 r.start=repair?L"开始修复":remove?L"开始卸载":L"开始安装";
 r.body=L"安装程序版本："+version+L"\n固定安装位置：\n"+root;
 if(!current.empty())r.body+=L"\n\n当前登记版本："+current;
 if(!remove&&!repair)r.body+=L"\n\n本次程序目录：\n"+root+L"\\versions\\"+version+L"\n\n升级保留个人词库、设置与设备组资料，不改变默认输入法。";
 else if(repair)r.body+=L"\n\n按现有已验证后台恢复程序登记，保留个人资料。修复完成后可再次普通安装更新。";
 else r.body+=L"\n\n移除已验证的输入服务与程序文件，保留个人词库、设置与设备组资料。占用或未知文件会保留并显示重试说明。";
 r.body+=L"\n\n点击“"+r.start+L"”后才开始处理；取消不会修改安装内容。";return r;
}
}
