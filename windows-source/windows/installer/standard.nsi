Unicode true
!include "MUI2.nsh"
!define APPNAME "灵鹤输入法"
!define VERSION "0.7.6-win1"
!define PUBLISHER "Pengbo Qin"
!define INSTDIR_DEFAULT "$PROGRAMFILES64\LingheInput"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\LingheInput.Standard"
!define OLDUNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\LingheInput.46A94BF1-285E-41D7-93F2-8B45E770C172"
Name "${APPNAME}"
OutFile "..\..\artifacts\LingheInput-Windows11-x64-0.7.6-standard-setup.exe"
InstallDir "${INSTDIR_DEFAULT}"
InstallDirRegKey HKLM "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel admin
Unicode true
SetCompressor /SOLID lzma
BrandingText "${APPNAME}"
VIProductVersion "0.7.6.1"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME}安装程序"
VIAddVersionKey "FileVersion" "0.7.6.1"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "GPL-3.0-only"
VIAddVersionKey "OriginalFilename" "LingheInput-Windows11-x64-0.7.6-standard-setup.exe"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "${APPNAME}"
!define MUI_WELCOMEPAGE_TEXT "安装 ${APPNAME} ${VERSION}。$\r$\n$\r$\n将安装并注册系统输入法，保留现有个人词库、设置和设备组资料，不改变默认输入法。$\r$\n$\r$\n本安装包是未签名的工程预览，Windows 可能显示发布者未知提示。"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "打开输入法设置"
!define MUI_FINISHPAGE_RUN_FUNCTION OpenSettings
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

Function OpenSettings
  ExecShell "open" "$INSTDIR\versions\${VERSION}\AMD64\LingheInputSettings.exe"
FunctionEnd

Function .onInit
  ; A previous custom preview may have its own ARP entry. The standard
  ; uninstaller replaces it; never leave two entries with the same product.
  DeleteRegKey HKLM "${OLDUNINSTKEY}"
FunctionEnd

Section "安装" SEC_INSTALL
  SetOutPath "$PLUGINSDIR\bootstrap"
  File /r "..\..\build\standard-installer-stage\*.*"
  ; The verified setup owns registration, rollback and data-preserving file
  ; transactions. This standard installer owns the wizard, ARP entry and
  ; uninstall lifecycle; --external-installer suppresses the old duplicate ARP.
  ExecWait '"$PLUGINSDIR\bootstrap\LingheInputSetup.exe" --install --quiet --external-installer' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "安装未完成（错误码 $0）。$\r$\n请保留此安装包并查看 Windows 的安装回执。个人词库与设置未被删除。"
    Abort
  ${EndIf}
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\versions\${VERSION}\AMD64\LingheInputSettings.exe"
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; External mode: the installed transactional setup unregisters the TSF and
  ; removes owned program files, but does not try to delete its own running
  ; executable or a duplicate ARP key. NSIS owns those final steps.
  ExecWait '"$INSTDIR\versions\${VERSION}\LingheInputSetup.exe" --uninstall --quiet --external-installer' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "卸载未完成（错误码 $0）。$\r$\n输入法登记和程序文件已保留，个人词库与设置未删除。"
    Abort
  ${EndIf}
  SetOutPath "$TEMP"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR\versions"
  RMDir /r "$INSTDIR\receipts"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "${OLDUNINSTKEY}"
  SetShellVarContext all
  Delete "$SMPROGRAMS\灵鹤输入法设置.lnk"
  Delete "$SMPROGRAMS\灵鹤输入法.lnk"
  RMDir "$SMPROGRAMS"
SectionEnd
