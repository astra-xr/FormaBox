Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"

Name "万象"
OutFile "${SETUP_EXE}"
InstallDir "$LOCALAPPDATA\Programs\FormaBox"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "${FORMABOX_VERSION}.0"
VIAddVersionKey /LANG=2052 "FileDescription" "万象安装向导"
VIAddVersionKey /LANG=2052 "ProductName" "万象"
VIAddVersionKey /LANG=2052 "ProductVersion" "${FORMABOX_VERSION}"
VIAddVersionKey /LANG=2052 "FileVersion" "${FORMABOX_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "FormaBox contributors"
VIAddVersionKey /LANG=2052 "LegalCopyright" "FormaBox contributors"

!define MUI_ABORTWARNING
!define MUI_ICON "${FORMABOX_ICON}"
!define MUI_UNICON "${FORMABOX_ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\FormaBox.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动万象"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox"

Function .onInit
    ${IfNot} ${RunningX64}
    ${OrIfNot} ${AtLeastBuild} 17763
        MessageBox MB_ICONSTOP "万象需要 64 位 Windows 10（1809 及以上）或 Windows 11。"
        Abort
    ${EndIf}
    ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "InstallLocation"
    ${If} $0 != ""
        MessageBox MB_ICONSTOP "请先卸载已安装的万象。安装向导会保留您的处理结果。" /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
FunctionEnd

Function .onVerifyInstDir
    FindFirst $0 $1 "$INSTDIR\*"
    ${While} $1 != ""
        ${If} $1 != "."
        ${AndIf} $1 != ".."
            FindClose $0
            SetErrorLevel 1
            Abort
        ${EndIf}
        FindNext $0 $1
    ${EndWhile}
    FindClose $0
FunctionEnd

Section "万象"
    Call .onVerifyInstDir
    SetOutPath "$INSTDIR"
    SetOverwrite on
    File /r "${PAYLOAD}\*"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    CreateShortCut "$SMPROGRAMS\万象.lnk" "$INSTDIR\FormaBox.exe"
    CreateShortCut "$DESKTOP\万象.lnk" "$INSTDIR\FormaBox.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "万象"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${FORMABOX_VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "FormaBox contributors"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" '"$INSTDIR\FormaBox.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
    !include "${UNINSTALL_LIST}"
    Delete "$SMPROGRAMS\万象.lnk"
    Delete "$DESKTOP\万象.lnk"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
