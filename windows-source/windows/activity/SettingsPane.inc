// Native settings UI only. Background transport/archiving remains in Worker.cpp.
HWND contentWindow=nullptr,learningSyncBox=nullptr,textSyncBox=nullptr,contentStatus=nullptr;
HWND settingsTitle=nullptr,settingsNav[2]{},settingsLearningNav=nullptr,syncSaveButton=nullptr,syncNowButton=nullptr;HFONT settingsTitleFont=nullptr,settingsSectionFont=nullptr;
std::vector<HWND>settingsSections;
int settingsPage=0,requestedSettingsPage=0,controlPage=-1;bool syncSettingsDirty=false;uint64_t syncDraftRevision=0;constexpr UINT SettingsSavedMessage=WM_APP+10;
Json clipboardLegacyDisplay=Json::array(),clipboardLiveDisplay=Json::array();
int px(int n){return MulDiv(n,int(uiDpi),96);}
void setFont(){
 HFONT next=settingsBodyFont(uiDpi),section=settingsHeadingFont(uiDpi);
 RECT area{};GetClientRect(window,&area);const int height=MulDiv(area.bottom,96,int(uiDpi));
 for(const auto&c:controls){int y=c.y,h=c.h;if(c.hwnd==statusField){y=height-50;h=38;}else if(c.hwnd==syncSaveButton||c.hwnd==syncNowButton||GetDlgCtrlID(c.hwnd)==5||GetDlgCtrlID(c.hwnd)==7||GetDlgCtrlID(c.hwnd)==8)y=height-94;SetWindowPos(c.hwnd,nullptr,px(c.x),px(y),px(c.w),px(h),SWP_NOZORDER|SWP_NOACTIVATE);SendMessageW(c.hwnd,WM_SETFONT,reinterpret_cast<WPARAM>(next),TRUE);}
 for(auto control:settingsSections)SendMessageW(control,WM_SETFONT,reinterpret_cast<WPARAM>(section),TRUE);
 if(uiFont)DeleteObject(uiFont);uiFont=next;if(settingsSectionFont)DeleteObject(settingsSectionFont);settingsSectionFont=section;
 if(settingsTitleFont)DeleteObject(settingsTitleFont);settingsTitleFont=settingsHeadingFont(uiDpi,true);if(settingsTitle)SendMessageW(settingsTitle,WM_SETFONT,reinterpret_cast<WPARAM>(settingsTitleFont),TRUE);
}
HWND control(const wchar_t*cls,const wchar_t*text,int x,int y,int w,int h,int id,DWORD style=0){
 auto hwnd=CreateWindowExW(std::wstring(cls)==L"EDIT"?WS_EX_CLIENTEDGE:0,cls,text,WS_CHILD|WS_VISIBLE|style,px(x),px(y),px(w),px(h),window,reinterpret_cast<HMENU>(INT_PTR(id)),nullptr,nullptr);
 controls.push_back({hwnd,x,y,w,h,controlPage});settingsControlTheme(hwnd);SendMessageW(hwnd,WM_SETFONT,reinterpret_cast<WPARAM>(uiFont),TRUE);return hwnd;
}
HWND section(const wchar_t*text,int y){auto label=control(L"STATIC",text,188,y,504,26,0);settingsSections.push_back(label);return label;}
void selectSettingsPage(int page){
 if(page<0||page>2)return;settingsPage=page;SetWindowTextW(settingsTitle,settingsSectionName(page==0?3:page==1?4:2));
 for(const auto&c:controls)ShowWindow(c.hwnd,c.page<0||c.page==page?SW_SHOW:SW_HIDE);
 for(auto control:{syncSaveButton,syncNowButton})ShowWindow(control,page==1?SW_HIDE:SW_SHOW);
 for(auto nav:settingsNav)InvalidateRect(nav,nullptr,TRUE);InvalidateRect(settingsLearningNav,nullptr,TRUE);
 SetFocus(page==2?settingsLearningNav:settingsNav[page]);
}
void createControls(){
 uiDpi=GetDpiForWindow(window);if(!uiDpi)uiDpi=96;settingsWindowIcon(window);settingsFitWindow(window,uiDpi);controlPage=-1;
 auto brand=control(L"STATIC",L"灵鹤输入法",28,32,136,28,0);settingsSections.push_back(brand);
 control(L"BUTTON",settingsSectionName(0),16,88,148,42,203,WS_TABSTOP|BS_OWNERDRAW);
 control(L"BUTTON",settingsSectionName(1),16,136,148,42,205,WS_TABSTOP|BS_OWNERDRAW);
 settingsLearningNav=control(L"BUTTON",settingsSectionName(2),16,184,148,42,204,WS_TABSTOP|BS_OWNERDRAW);
 settingsNav[0]=control(L"BUTTON",settingsSectionName(3),16,232,148,42,201,WS_TABSTOP|BS_OWNERDRAW);
 settingsNav[1]=control(L"BUTTON",settingsSectionName(4),16,280,148,42,202,WS_TABSTOP|BS_OWNERDRAW);
 if(fixtureMode)for(int id:{203,205})EnableWindow(GetDlgItem(window,id),FALSE);
 settingsTitle=control(L"STATIC",L"设备与同步",188,26,504,36,0);
 statusField=control(L"STATIC",L"正在读取本机同步状态…",188,470,504,38,0);contentStatus=statusField;
 syncSaveButton=control(L"BUTTON",L"保存同步设置",532,426,160,34,23,WS_TABSTOP);
 syncNowButton=control(L"BUTTON",L"立即同步",388,426,128,34,24,WS_TABSTOP);
 controlPage=0;
 section(L"连接设备组",78);
 control(L"STATIC",L"同步服务器",188,112,504,22,0);
 relayField=control(L"EDIT",L"",188,140,504,32,101,WS_TABSTOP|ES_AUTOHSCROLL);settingsInputScope(relayField,IS_URL);SendMessageW(relayField,EM_SETLIMITTEXT,2048,0);
 control(L"STATIC",L"六位接入码",188,188,130,22,0);
 codeField=control(L"EDIT",L"",188,216,130,32,102,WS_TABSTOP|ES_NUMBER);settingsInputScope(codeField,IS_DIGITS);SendMessageW(codeField,EM_SETLIMITTEXT,6,0);
 control(L"BUTTON",L"加入设备组",334,214,170,34,1,WS_TABSTOP);
 control(L"BUTTON",L"新建设备组",520,214,172,34,2,WS_TABSTOP);
 control(L"BUTTON",L"生成接入码",188,266,158,34,9,WS_TABSTOP);
 control(L"BUTTON",L"关闭接入码",361,266,158,34,10,WS_TABSTOP);
 control(L"BUTTON",L"退出设备组…",534,266,158,34,3,WS_TABSTOP);
 ticketField=control(L"STATIC",L"",188,310,504,24,0);
 textSyncBox=control(L"BUTTON",L"自动同步剪贴板文字",188,342,504,32,22,WS_TABSTOP|BS_AUTOCHECKBOX);
 controlPage=2;
 section(L"输入习惯",78);
 learningSyncBox=control(L"BUTTON",L"同步本组词库与输入习惯",188,118,504,32,21,WS_TABSTOP|BS_AUTOCHECKBOX);
 control(L"STATIC",L"包含个人词条、快捷短语和使用频率。",188,164,504,40,0);
 controlPage=1;
 control(L"STATIC",L"归档服务器",188,82,504,22,0);
 archiveField=control(L"EDIT",L"",188,110,504,32,103,WS_TABSTOP|ES_AUTOHSCROLL);settingsInputScope(archiveField,IS_URL);SendMessageW(archiveField,EM_SETLIMITTEXT,2048,0);
 control(L"BUTTON",L"开启本组归档…",188,154,176,34,4,WS_TABSTOP);
 section(L"本设备记录范围",194);
 imeBox=control(L"BUTTON",L"输入法输出",188,228,504,30,104,WS_TABSTOP|BS_AUTOCHECKBOX);
 clipboardBox=control(L"BUTTON",L"剪贴板文字",188,262,504,30,105,WS_TABSTOP|BS_AUTOCHECKBOX);
 diagnosticBox=control(L"BUTTON",L"输入过程（包含未发送内容）",188,296,504,30,106,WS_TABSTOP|BS_AUTOCHECKBOX);
 control(L"STATIC",L"勾选内容会以明文保存在归档服务器。\r\n密码字段、安全桌面及系统无法读取的内容不记录。",188,336,504,40,0);
 control(L"BUTTON",L"清空本机归档…",188,426,160,34,7,WS_TABSTOP);
 control(L"BUTTON",L"刷新状态",364,426,136,34,8,WS_TABSTOP);
 control(L"BUTTON",L"保存本设备授权…",516,426,176,34,5,WS_TABSTOP);
 contentWindow=window;controlPage=-1;setFont();selectSettingsPage(requestedSettingsPage);
 for(int id:{21,22,23,24})EnableWindow(GetDlgItem(window,id),FALSE);
}
void renderSharedTexts(){/* No desktop history or message presentation. */}
void updateContent(){publishLearning();if(!client)return;refreshAutomaticClipboard();auto snapshot=client->contentSnapshot();snapshot["automaticClipboardEnabled"]=automaticClipboard&&automaticClipboard->enabled();snapshot["automaticClipboardReady"]=automaticClipboard&&automaticClipboard->ready();auto*value=new Json(snapshot);if(!PostMessageW(window,ContentMessage,0,reinterpret_cast<LPARAM>(value)))delete value;}

void openContent(){selectSettingsPage(0);submit([]{updateContent();});}
bool settingsCommand(int id){
 if(id==201||id==202||id==204){selectSettingsPage(id==204?2:id-201);return true;}
 if(id==203||id==205){if(fixtureMode)return true;wchar_t path[32768]{};auto count=GetModuleFileNameW(nullptr,path,32768);if(count&&count<32768){auto exe=std::filesystem::path(path).parent_path()/L"LingheInputSettings.exe";if(reinterpret_cast<INT_PTR>(ShellExecuteW(window,L"open",exe.c_str(),id==205?L"--appearance":nullptr,exe.parent_path().c_str(),SW_SHOWNORMAL))<=32)MessageBoxW(window,L"输入设置暂时无法打开。",L"灵鹤输入法",MB_OK|MB_ICONERROR);}return true;}
 if(id==21||id==22){syncSettingsDirty=true;++syncDraftRevision;return true;}
 if(id==24){submit([]{syncContentWithAutomaticClipboard();updateContent();statusSummary(L"同步完成。");});return true;}
 if(id!=23)return false;
 bool learning=SendMessageW(learningSyncBox,BM_GETCHECK,0,0)==BST_CHECKED;
 bool clipboard=SendMessageW(textSyncBox,BM_GETCHECK,0,0)==BST_CHECKED;
 const auto draft=syncDraftRevision;const auto revision=++automaticPreferenceRevision;refreshClipboardCandidatePermission(false);clearClipboardCandidate();
 automaticClipboardUserPaused=true;automaticClipboardRequestedOff=true;clipboardReadSafety.invalidate();cancelClipboardReadRetry();suspendLiveClipboard();automaticClipboardActive=false;advanceAutomaticGeneration();
 submit([learning,clipboard,revision,draft]{
  // Fail closed while two existing durable stores change. No new collection grant.
  refreshAutomaticClipboard();automaticClipboard->setEnabled(false);client->consentContent(learning,clipboard);automaticClipboard->setEnabled(clipboard);
  if(automaticPreferenceRevision==revision){automaticClipboardRequestedOff=!clipboard;automaticClipboardUserPaused=false;}
  refreshAutomaticClipboard();lastContentSync=0;PostMessageW(window,SettingsSavedMessage,WPARAM(draft),0);updateContent();runAtLogon(learning||clipboard||(gate&&gate->enabled)||clipboardEnabled);statusSummary(L"同步设置已保存。剪贴板在后台自动同步。");
 });return true;
}
