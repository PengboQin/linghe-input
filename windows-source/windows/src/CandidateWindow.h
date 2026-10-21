#pragma once
#include <windows.h>
#include <functional>
#include <string>
#include <vector>
#include "desktop_candidates.hpp"
#include "CandidateLayout.h"
#include "DesktopTheme.h"
class CandidateWindow {
 std::optional<size_t>pressed;unsigned long long pressedRevision=0;bool managementEnabled=true;
 HWND window=nullptr;HFONT font=nullptr;std::vector<std::wstring> labels;
 private_input::DesktopCandidates navigation;private_input::CandidateLayout layout;unsigned long long revision=0;UINT displayDpi=96;
 std::function<void(size_t,unsigned long long,unsigned)>manage;std::function<bool(size_t)>pinned;
 std::function<void(size_t,unsigned long long)> choose;std::function<void(int)> wheel;
 static LRESULT CALLBACK procedure(HWND,UINT,WPARAM,LPARAM);void paint();
public:
 explicit CandidateWindow(std::function<void(size_t,unsigned long long)> callback,std::function<void(int)> scroll={}):choose(std::move(callback)),wheel(std::move(scroll)){}
 ~CandidateWindow();
 void show(HINSTANCE,const RECT&,const std::vector<std::wstring>&,unsigned long long,UINT=96,const private_input::DesktopCandidates& = {});
 void setManagement(std::function<void(size_t,unsigned long long,unsigned)>action,std::function<bool(size_t)>state){manage=std::move(action);pinned=std::move(state);}
 void allowManagement(bool enabled){managementEnabled=enabled;}
 void hide();void setTheme(private_input::DesktopTheme value){theme=value;}
 private: private_input::DesktopTheme theme;bool systemDark=false;
};
