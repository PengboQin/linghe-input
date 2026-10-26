// Native settings UI only. Background transport/archiving remains in Worker.cpp.
HWND contentWindow=nullptr,learningSyncBox=nullptr,textSyncBox=nullptr,contentStatus=nullptr;
HWND settingsTitle=nullptr,settingsNav[2]{},settingsLearningNav=nullptr,syncSaveButton=nullptr,syncNowButton=nullptr;HFONT settingsTitleFont=nullptr,settingsSectionFont=nullptr;
std::vector<HWND>settingsSections;
int settingsPage=0,requestedSettingsPage=0,controlPage=-1;bool syncSettingsDirty=false;uint64_t syncDraftRevision=0;constexpr UINT SettingsSavedMessage=WM_APP+10;
Json clipboardLegacyDisplay=Json::array(),clipboardLiveDisplay=Json::array();
// Input settings and appearance live in this same window (pages 3/4); the old
// LingheInputSettings.exe only forwards here. Same file and JSON as before.
HWND inputFields[5]{},pairSymbolsBox=nullptr,caretInsideBox=nullptr,inputSaveButton=nullptr;
std::filesystem::path inputPreferencesFile(){return (fixtureMode?privateRoot.parent_path():userRoot())/L"desktop-candidate-layout-v1.json";}
int px(int n){return MulDiv(n,int(uiDpi),96);}
void setFont(){
 HFONT next=settingsBodyFont(uiDpi),section=settingsHeadingFont(uiDpi);
 RECT area{};GetClientRect(window,&area);const int height=MulDiv(area.bottom,96,int(uiDpi));
 for(const auto&c:controls){int y=c.y,h=c.h;if(c.hwnd==statusField){y=height-50;h=38;}else if(c.hwnd==syncSaveButton||c.hwnd==syncNowButton||GetDlgCtrlID(c.hwnd)==5||GetDlgCtrlID(c.hwnd)==7||GetDlgCtrlID(c.hwnd)==8)y=height-94;SetWindowPos(c.hwnd,nullptr,px(c.x),px(y),px(c.w),px(h),SWP_NOZORDER|SWP_NOACTIVATE);SendMessageW(c.hwnd,WM_SETFONT,reinterpret_cast<WPARAM>(next),TRUE);}
 for(auto control:settingsSections)SendMessageW(control,WM_SETFONT,reinterpret_cast<WPARAM>(section),TRUE);
 for(auto field:inputFields)if(field){SendMessageW(field,CB_SETITEMHEIGHT,WPARAM(-1),px(24));SendMessageW(field,CB_SETITEMHEIGHT,0,px(24));}
 if(uiFont)DeleteObject(uiFont);uiFont=next;if(settingsSectionFont)DeleteObject(settingsSectionFont);settingsSectionFont=section;
 if(settingsTitleFont)DeleteObject(settingsTitleFont);settingsTitleFont=settingsHeadingFont(uiDpi,true);if(settingsTitle)SendMessageW(settingsTitle,WM_SETFONT,reinterpret_cast<WPARAM>(settingsTitleFont),TRUE);
}
HWND control(const wchar_t*cls,const wchar_t*text,int x,int y,int w,int h,int id,DWORD style=0){
 auto hwnd=CreateWindowExW(std::wstring(cls)==L"EDIT"?WS_EX_CLIENTEDGE:0,cls,text,WS_CHILD|WS_VISIBLE|style,px(x),px(y),px(w),px(h),window,reinterpret_cast<HMENU>(INT_PTR(id)),nullptr,nullptr);
 controls.push_back({hwnd,x,y,w,h,controlPage});settingsControlTheme(hwnd);SendMessageW(hwnd,WM_SETFONT,reinterpret_cast<WPARAM>(uiFont),TRUE);return hwnd;
}
HWND section(const wchar_t*text,int y){auto label=control(L"STATIC",text,188,y,504,26,0);settingsSections.push_back(label);return label;}
// Pages: 0 devices, 1 privacy, 2 learning, 3 input, 4 appearance.
int settingsSectionOf(int page){static constexpr int map[]={3,4,2,0,1};return page>=0&&page<5?map[page]:3;}
int settingsNavId(int page){static constexpr int ids[]={201,202,204,203,205};return page>=0&&page<5?ids[page]:201;}
void selectSettingsPage(int page){
 if(page<0||page>4)return;settingsPage=page;settingsSurfacePage(window,settingsSectionOf(page));SetWindowTextW(settingsTitle,settingsSectionName(settingsSectionOf(page)));
 for(const auto&c:controls)ShowWindow(c.hwnd,c.page<0||c.page==page?SW_SHOW:SW_HIDE);
 for(auto control:{syncSaveButton,syncNowButton})ShowWindow(control,page==0||page==2?SW_SHOW:SW_HIDE);
 ShowWindow(inputSaveButton,page>=3?SW_SHOW:SW_HIDE);
 for(int id:{201,202,203,204,205})InvalidateRect(GetDlgItem(window,id),nullptr,TRUE);
 SetFocus(GetDlgItem(window,settingsNavId(page)));
}
void saveInputPreferences(){
 int values[3];for(int i=0;i<3;i++){auto index=SendMessageW(inputFields[i],CB_GETCURSEL,0,0);require(index>=0&&index<=6,"input selection");values[i]=int(index)+3;}
 const char*modes[]={"system","light","dark"};const char*accents[]={"rose","amber","violet","graphite"};auto mode=SendMessageW(inputFields[3],CB_GETCURSEL,0,0),accent=SendMessageW(inputFields[4],CB_GETCURSEL,0,0);require(mode>=0&&mode<=2&&accent>=0&&accent<=3,"theme selection");
 auto json=std::string("{\"collapsedCount\":")+std::to_string(values[0])+",\"expandedColumns\":"+std::to_string(values[1])+",\"expandedRows\":"+std::to_string(values[2])+",\"themeMode\":\""+modes[mode]+"\",\"themeAccent\":\""+accents[accent]+"\",\"pairSymbols\":"+(SendMessageW(pairSymbolsBox,BM_GETCHECK,0,0)==BST_CHECKED?"true":"false")+",\"caretInside\":"+(SendMessageW(caretInsideBox,BM_GETCHECK,0,0)==BST_CHECKED?"true":"false")+"}\n";
 const auto file=inputPreferencesFile();std::filesystem::create_directories(file.parent_path());
 // Same exclusive lock name as the former settings program: no lost writes.
 auto lockPath=file;lockPath+=L".save-lock";HANDLE lock=CreateFileW(lockPath.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,nullptr);require(lock!=INVALID_HANDLE_VALUE,"settings busy");
 auto temporary=file;temporary+=L"."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(GetTickCount64())+L".tmp";
 HANDLE output=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(output==INVALID_HANDLE_VALUE){CloseHandle(lock);require(false,"settings temporary");}
 DWORD written=0;bool ok=WriteFile(output,json.data(),DWORD(json.size()),&written,nullptr)&&written==json.size()&&FlushFileBuffers(output);CloseHandle(output);
 ok=ok&&MoveFileExW(temporary.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);if(!ok)DeleteFileW(temporary.c_str());CloseHandle(lock);require(ok,"settings write");
}
void createControls(){
 uiDpi=GetDpiForWindow(window);if(!uiDpi)uiDpi=96;settingsWindowIcon(window);settingsInstallSurface(window,mainTheme);settingsFitWindow(window,uiDpi);controlPage=-1;
 auto brand=control(L"STATIC",L"灵鹤输入法",60,32,104,28,0);settingsSections.push_back(brand);
 control(L"BUTTON",settingsSectionName(0),16,88,148,42,203,WS_TABSTOP|BS_OWNERDRAW);
 control(L"BUTTON",settingsSectionName(1),16,136,148,42,205,WS_TABSTOP|BS_OWNERDRAW);
 settingsLearningNav=control(L"BUTTON",settingsSectionName(2),16,184,148,42,204,WS_TABSTOP|BS_OWNERDRAW);
 settingsNav[0]=control(L"BUTTON",settingsSectionName(3),16,232,148,42,201,WS_TABSTOP|BS_OWNERDRAW);
 settingsNav[1]=control(L"BUTTON",settingsSectionName(4),16,280,148,42,202,WS_TABSTOP|BS_OWNERDRAW);
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
 ticketField=control(L"STATIC",L"",188,306,504,22,0);
 textSyncBox=control(L"BUTTON",L"自动同步剪贴板文字",188,342,504,32,22,WS_TABSTOP|BS_AUTOCHECKBOX);
 controlPage=2;
 section(L"输入习惯",78);
 learningSyncBox=control(L"BUTTON",L"同步本组词库与输入习惯",188,118,504,32,21,WS_TABSTOP|BS_AUTOCHECKBOX);
 control(L"STATIC",L"包含个人词条、快捷短语和使用频率。",188,164,504,40,0);
 controlPage=1;
 control(L"STATIC",L"归档服务器",188,82,504,22,0);
 archiveField=control(L"EDIT",L"",188,110,504,32,103,WS_TABSTOP|ES_AUTOHSCROLL);settingsInputScope(archiveField,IS_URL);SendMessageW(archiveField,EM_SETLIMITTEXT,2048,0);
 control(L"BUTTON",L"开启本组归档…",188,154,176,34,4,WS_TABSTOP);
 section(L"本设备记录范围",202);
 imeBox=control(L"BUTTON",L"输入法输出",188,228,504,30,104,WS_TABSTOP|BS_AUTOCHECKBOX);
 clipboardBox=control(L"BUTTON",L"剪贴板文字",188,262,504,30,105,WS_TABSTOP|BS_AUTOCHECKBOX);
 diagnosticBox=control(L"BUTTON",L"输入过程（包含未发送内容）",188,296,504,30,106,WS_TABSTOP|BS_AUTOCHECKBOX);
 control(L"STATIC",L"勾选内容会以明文保存在归档服务器。\r\n密码字段、安全桌面及系统无法读取的内容不记录。",188,336,504,40,0);
 control(L"BUTTON",L"清空本机归档…",188,426,160,34,7,WS_TABSTOP);
 control(L"BUTTON",L"刷新状态",364,426,136,34,8,WS_TABSTOP);
 control(L"BUTTON",L"保存本设备授权…",516,426,176,34,5,WS_TABSTOP);
 SetWindowPos(syncNowButton,GetDlgItem(window,5),0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
 SetWindowPos(syncSaveButton,syncNowButton,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
 settingsPrimaryButton(syncSaveButton);settingsPrimaryButton(GetDlgItem(window,5));
 {const auto file=inputPreferencesFile();auto layoutState=readDesktopLayout(file);auto preferences=readDesktopInputPreferences(file);
  int values[]={layoutState.collapsed,layoutState.columns,layoutState.rows,preferences.theme.mode+3,preferences.theme.accent+3};const wchar_t*names[]={L"单行候选数(&C)",L"展开列数(&L)",L"展开行数(&R)",L"明暗外观",L"主题色"};
  controlPage=3;section(L"候选词",78);section(L"符号与光标",256);
  for(int i=0;i<5;i++){if(i==3){controlPage=4;section(L"主题",78);}const int row=i<3?112+i*44:112+(i-3)*44;
   control(L"STATIC",names[i],188,row+5,288,26,0,SS_LEFT);
   inputFields[i]=control(L"COMBOBOX",L"",512,row,180,220,140+i,WS_TABSTOP|CBS_DROPDOWNLIST|CBS_OWNERDRAWFIXED|CBS_HASSTRINGS|WS_VSCROLL);
   if(i<3){for(int n=3;n<=9;n++)SendMessageW(inputFields[i],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(std::to_wstring(n).c_str()));}
   else{const wchar_t*modes[]={L"跟随系统",L"浅色",L"深色"};const wchar_t*accents[]={L"胭脂",L"琥珀",L"紫藤",L"石墨"};for(int n=0;n<(i==3?3:4);++n)SendMessageW(inputFields[i],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(i==3?modes[n]:accents[n]));}
   SendMessageW(inputFields[i],CB_SETCURSEL,values[i]-3,0);
   if(i==2){pairSymbolsBox=control(L"BUTTON",L"自动输入成对符号",188,296,504,32,150,WS_TABSTOP|BS_AUTOCHECKBOX);caretInsideBox=control(L"BUTTON",L"输入成对符号后光标居中",188,338,504,32,151,WS_TABSTOP|BS_AUTOCHECKBOX);
    SendMessageW(pairSymbolsBox,BM_SETCHECK,preferences.pairSymbols?BST_CHECKED:BST_UNCHECKED,0);SendMessageW(caretInsideBox,BM_SETCHECK,preferences.caretInside?BST_CHECKED:BST_UNCHECKED,0);EnableWindow(caretInsideBox,preferences.pairSymbols);}
  }
  controlPage=-1;inputSaveButton=control(L"BUTTON",L"保存",568,426,124,34,31,WS_TABSTOP);settingsPrimaryButton(inputSaveButton);EnableWindow(inputSaveButton,FALSE);}
 contentWindow=window;controlPage=-1;setFont();selectSettingsPage(requestedSettingsPage);
 for(int id:{21,22,23,24})EnableWindow(GetDlgItem(window,id),FALSE);
}
void renderSharedTexts(){/* No desktop history or message presentation. */}
void updateContent(){publishLearning();if(!client)return;refreshAutomaticClipboard();auto snapshot=client->contentSnapshot();snapshot["automaticClipboardEnabled"]=automaticClipboard&&automaticClipboard->enabled();snapshot["automaticClipboardReady"]=automaticClipboard&&automaticClipboard->ready();auto*value=new Json(snapshot);if(!PostMessageW(window,ContentMessage,0,reinterpret_cast<LPARAM>(value)))delete value;}

void openContent(){selectSettingsPage(0);submit([]{updateContent();});}
bool settingsCommand(int id){
 if(id==201||id==202||id==204){selectSettingsPage(id==204?2:id-201);return true;}
 if(id==203||id==205){selectSettingsPage(id==203?3:4);return true;}
 if(id>=140&&id<=144){EnableWindow(inputSaveButton,TRUE);return true;}
 if(id==150||id==151){EnableWindow(caretInsideBox,SendMessageW(pairSymbolsBox,BM_GETCHECK,0,0)==BST_CHECKED);EnableWindow(inputSaveButton,TRUE);return true;}
 if(id==31){if(!IsWindowEnabled(inputSaveButton))return true;
  try{saveInputPreferences();mainTheme.apply(window,appearance().theme);InvalidateRect(window,nullptr,TRUE);EnableWindow(inputSaveButton,FALSE);SetWindowTextW(statusField,L"输入设置已保存。");}
  catch(...){MessageBoxW(window,L"设置未能保存，请稍后重试。",L"灵鹤输入法",MB_OK|MB_ICONERROR);}return true;}
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
