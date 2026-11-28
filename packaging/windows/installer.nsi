Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "WordFunc.nsh"

Name "万象（Omnora）"
OutFile "${SETUP_EXE}"
InstallDir "$LOCALAPPDATA\Programs\Omnora"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "${FORMABOX_VERSION}.0"
VIAddVersionKey /LANG=2052 "FileDescription" "万象（Omnora）安装向导"
VIAddVersionKey /LANG=2052 "ProductName" "万象（Omnora）"
VIAddVersionKey /LANG=2052 "ProductVersion" "${FORMABOX_VERSION}"
VIAddVersionKey /LANG=2052 "FileVersion" "${FORMABOX_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "Omnora contributors"
VIAddVersionKey /LANG=2052 "LegalCopyright" "FormaBox contributors"

!define MUI_ABORTWARNING
!define MUI_ICON "${FORMABOX_ICON}"
!define MUI_UNICON "${FORMABOX_ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Omnora.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动万象"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

; Reuse the existing product identity so upgrades still detect older installations.
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox"
Var PreviousLocation
Var PreviousVersion
Var TransactionTool
Var SetupMutex
Var SetupLog
Var Failure

Function .onInit
    ${IfNot} ${RunningX64}
    ${OrIfNot} ${AtLeastBuild} 17763
        MessageBox MB_ICONSTOP "万象需要 64 位 Windows 10（1809 及以上）或 Windows 11。"
        Abort
    ${EndIf}
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\Omnora.Setup") p .r0 ?e'
    Pop $1
    StrCpy $SetupMutex $0
    ${If} $SetupMutex == 0
    ${OrIf} $1 == 183
        MessageBox MB_ICONSTOP "另一个万象安装向导正在运行。" /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    ReadRegStr $PreviousLocation HKCU "${UNINSTALL_KEY}" "InstallLocation"
    ReadRegStr $PreviousVersion HKCU "${UNINSTALL_KEY}" "DisplayVersion"
    ${If} $PreviousLocation != ""
        ${VersionCompare} "$PreviousVersion" "${FORMABOX_VERSION}" $0
        ${If} $0 == 1
            MessageBox MB_ICONSTOP "已安装较新的万象。请使用对应版本的安装向导。" /SD IDOK
            SetErrorLevel 1
            Abort
        ${EndIf}
    ${EndIf}
FunctionEnd

Function .onVerifyInstDir
    ${If} $PreviousLocation != ""
        ${If} $INSTDIR != $PreviousLocation
            SetErrorLevel 1
            Abort
        ${EndIf}
        ${If} ${FileExists} "$INSTDIR\Uninstall.exe"
        ${OrIf} ${FileExists} "$INSTDIR\.omnora-setup\owner"
            Return
        ${EndIf}
        SetErrorLevel 1
        Abort
    ${EndIf}
    FindFirst $0 $1 "$INSTDIR\*"
    ${While} $1 != ""
        ${If} $1 != "."
        ${AndIf} $1 != ".."
        ${AndIf} $1 != ".omnora-setup"
            FindClose $0
            SetErrorLevel 1
            SetErrorLevel 1
            Abort
        ${EndIf}
        FindNext $0 $1
    ${EndWhile}
    FindClose $0
FunctionEnd

Function LogSetup
    Exch $0
    Push $1
    DetailPrint "$0"
    ClearErrors
    FileOpen $1 "$SetupLog" a
    IfErrors setup_log_done
    FileSeek $1 0 END
    FileWriteUTF16LE $1 "$0$\r$\n"
    FileClose $1
setup_log_done:
    Pop $1
    Pop $0
FunctionEnd

Section "万象"
    Call .onVerifyInstDir
    CreateDirectory "$LOCALAPPDATA\Omnora"
    StrCpy $SetupLog "$LOCALAPPDATA\Omnora\installer.log"
    Push "开始安装 ${FORMABOX_VERSION}，已安装版本 $PreviousVersion"
    Call LogSetup
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File /oname=OmnoraInstallTransaction.exe "${TRANSACTION_EXE}"
    StrCpy $TransactionTool "$PLUGINSDIR\OmnoraInstallTransaction.exe"
    ClearErrors
    ExecWait '"$TransactionTool" recover "$INSTDIR" ""' $0
    IfErrors transaction_prepare_failed
    StrCmp $0 0 +2
    Goto transaction_prepare_failed
    ReadRegStr $PreviousVersion HKCU "${UNINSTALL_KEY}" "DisplayVersion"
    ClearErrors
    ExecWait '"$TransactionTool" prepare "$INSTDIR" "$PreviousVersion"' $0
    IfErrors transaction_prepare_failed
    StrCmp $0 0 transaction_prepare_ready
transaction_prepare_failed:
    StrCpy $Failure "无法准备或恢复安装事务（$0）"
    Goto transaction_failed
transaction_prepare_ready:
    ClearErrors
    SetOutPath "$INSTDIR\.omnora-setup\payload"
    SetOverwrite on
    File /r "${PAYLOAD}\*"
    IfErrors transaction_extraction_failed
    WriteUninstaller "$INSTDIR\.omnora-setup\payload\Uninstall.exe"
    IfErrors transaction_extraction_failed
    SetOutPath "$PLUGINSDIR"
    ClearErrors
    ExecWait '"$TransactionTool" apply "$INSTDIR" ""' $0
    IfErrors transaction_apply_failed
    StrCmp $0 0 transaction_apply_ready
transaction_apply_failed:
    StrCpy $Failure "无法替换程序文件（$0）。请先关闭正在运行的万象。"
    Goto transaction_rollback
transaction_extraction_failed:
    StrCpy $Failure "无法解包完整的安装文件"
    Goto transaction_rollback
transaction_apply_ready:
    Push "已暂存并切换程序文件，正在验证新版本"
    Call LogSetup
    ClearErrors
    ExecWait '"$INSTDIR\Omnora.exe" --verify-install' $0
    IfErrors transaction_verify_failed
    StrCmp $0 0 transaction_register
transaction_verify_failed:
    StrCpy $Failure "新版启动验证失败（$0）"
    Goto transaction_rollback
transaction_register:
    ClearErrors
    CreateShortCut "$SMPROGRAMS\万象（Omnora）.lnk" "$INSTDIR\Omnora.exe"
    CreateShortCut "$DESKTOP\万象（Omnora）.lnk" "$INSTDIR\Omnora.exe"
    CreateShortCut "$SENDTO\万象（Omnora）.lnk" "$INSTDIR\Omnora.exe" "--send-to"
    CreateShortCut "$SENDTO\万象 - Office 转 PDF.lnk" "$INSTDIR\Omnora.exe" "--quick-office --send-to"
    CreateShortCut "$SENDTO\万象 - 图片压缩到 100 KiB.lnk" "$INSTDIR\Omnora.exe" "--quick-photo --send-to"
    IfErrors transaction_registration_failed
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    IfErrors transaction_registration_failed
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "万象（Omnora）"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Omnora contributors"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" '"$INSTDIR\Omnora.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${FORMABOX_VERSION}"
    IfErrors transaction_registration_failed
    ExecWait '"$TransactionTool" accept "$INSTDIR" ""' $0
    IfErrors transaction_registration_failed
    StrCmp $0 0 transaction_complete
transaction_registration_failed:
    StrCpy $Failure "无法登记新版本（$0）"
transaction_rollback:
    ClearErrors
    SetOutPath "$PLUGINSDIR"
    ExecWait '"$TransactionTool" recover "$INSTDIR" ""' $1
    IfErrors transaction_recovery_failed
    StrCmp $1 0 transaction_recovered
transaction_recovery_failed:
    Push "回滚尚未完成（$1），请关闭万象并再次运行安装向导"
    Call LogSetup
    Goto transaction_failed
transaction_recovered:
    Push "已回滚程序文件"
    Call LogSetup
transaction_failed:
    Push "$Failure"
    Call LogSetup
    MessageBox MB_ICONSTOP "$Failure$\r$\n详情见 $SetupLog" /SD IDOK
    SetErrorLevel 1
    Abort
transaction_complete:
    ${If} $PreviousVersion == "0.9.0"
        Delete "$SMPROGRAMS\万象.lnk"
        Delete "$DESKTOP\万象.lnk"
        Delete "$SENDTO\万象（FormaBox）.lnk"
        Delete "$INSTDIR\FormaBox.exe"
    ${EndIf}
    Push "安装完成 ${FORMABOX_VERSION}"
    Call LogSetup
SectionEnd

Section "Uninstall"
    !include "${UNINSTALL_LIST}"
    Delete "$SMPROGRAMS\万象（Omnora）.lnk"
    Delete "$DESKTOP\万象（Omnora）.lnk"
    Delete "$SENDTO\万象（Omnora）.lnk"
    Delete "$SENDTO\万象 - Office 转 PDF.lnk"
    Delete "$SENDTO\万象 - 图片压缩到 100 KiB.lnk"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
