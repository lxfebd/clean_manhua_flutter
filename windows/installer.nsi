; ============================================================
;  星漫匣 Windows 安装程序（NSIS Modern UI 2）
; ============================================================
; 构建（CI / 本地）：
;   makensis 只认 UTF-16LE 或纯 ASCII 脚本。本文件以 UTF-8 存储，
;   编译前先转 UTF-16LE（PowerShell）：
;     $t = Get-Content -Raw -Encoding UTF8 windows/installer.nsi
;     [IO.File]::WriteAllText("$env:TEMP\installer_u16.nsi", $t,
;                             [Text.Encoding]::Unicode)
;     makensis -DAPP_VERSION=1.5.0 "$env:TEMP\installer_u16.nsi"
; 产物：xingmanxia-windows-<APP_VERSION>-setup.exe（位于仓库根）
;
; 两种用法（同一脚本）：
;   手动安装  xingmanxia-windows-1.5.0-setup.exe
;             （带向导，用户可选目录，装完自动启动）
;   静默更新  xingmanxia-windows-1.5.0-setup.exe /S /D="J:\xingmanxia-windows-1.4.0"
;             （app 内「更新」用，无界面；/D 指向 app 当前运行的目录，原地覆盖升级）
;
; 关键设计：
;   - RequestExecutionLevel user —— 默认装到用户目录，静默更新不会被 UAC 卡住
;   - 卸载不碰用户数据：书架/设置在 %LOCALAPPDATA%\com.xingmanxia.app，
;     与安装目录完全独立，卸载只删本目录内的运行时文件
;   - Section -Post 总是 Exec 新版 exe：静默更新时 app 先退出 → installer 覆盖 →
;     自动拉起新版，全程用户无感；手动安装时也在 Finish 页后自动启动
;   - 静默模式先 RMDir 再 File：Flutter 升级可能删除某些 dll，原地覆盖会留下
;     废弃文件；清掉再拷是干净升级。手动模式绝不清理（用户可能选了别的目录）
; ============================================================

; ---- 压缩：必须在任何产生数据的命令（含 MUI 页面宏）之前 ----------------
SetCompressor /SOLID lzma

; ---- 包含与标识 --------------------------------------------------------
!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif

!define PRODUCT_EXE "yingmanhe_clean.exe"
!define PRODUCT_DIR "XingManXia"
!define UNINSTALL_KEY "XingManXia"
!define UNINSTALL_EXE "Uninstall XingManXia.exe"

; ---- 安装器 UI ----------------------------------------------------------
!define MUI_ICON "windows\runner\resources\app_icon.ico"
!define MUI_UNICON "windows\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Name "星漫匣"
OutFile "xingmanxia-windows-${APP_VERSION}-setup.exe"
; 用户级安装目录，无需管理员权限，静默更新不会被 UAC 卡住
InstallDir "$LOCALAPPDATA\Programs\${PRODUCT_DIR}"
RequestExecutionLevel user
SetOverwrite on

; ---- 安装 ----------------------------------------------------------------
Section "Install"
  ${if} ${Silent}
    ; app 是「启动本 installer 后马上退出」的。Windows 上运行中的 exe 处于文件
    ; 锁状态，此刻 File 覆盖必失败。给进程退出并释放句柄留时间（2.5s 足够）。
    Sleep 1500
    Sleep 500
    Sleep 500

    ; 干净升级：清掉旧目录再拷新版。只覆盖 dll/exe/data 等运行时文件，
    ; 用户数据在 %LOCALAPPDATA%\com.xingmanxia.app，不在 $INSTDIR 内，不受影响。
    RMDir /r "$INSTDIR"
  ${endif}

  SetOutPath "$INSTDIR"
  File /r "build\windows\x64\runner\Release\*"

  WriteUninstaller "$INSTDIR\${UNINSTALL_EXE}"

  ; 注册表卸载项（控制面板「程序和功能」可见）
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "DisplayName" "星漫匣"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "UninstallString" '"$INSTDIR\${UNINSTALL_EXE}"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "QuietUninstallString" '"$INSTDIR\${UNINSTALL_EXE}" /S'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}" \
    "NoRepair" 1

  ; 开始菜单快捷方式（手动与静默都建，保证卸载时能找到快捷方式路径）
  CreateDirectory "$SMPROGRAMS\星漫匣"
  CreateShortcut "$SMPROGRAMS\星漫匣\星漫匣.lnk" "$INSTDIR\${PRODUCT_EXE}"
  CreateShortcut "$SMPROGRAMS\星漫匣\卸载星漫匣.lnk" "$INSTDIR\${UNINSTALL_EXE}"
SectionEnd

; 静默与手动都执行：拉起刚装好的新版。Exec 非阻塞——installer 结束的同时
; 新版已在启动。这是「下载完就自动变成新版」的关键一步。
Section -Post
  Exec '"$INSTDIR\${PRODUCT_EXE}"'
SectionEnd

; ---- 卸载 ----------------------------------------------------------------
Section "Uninstall"
  ; 只删安装目录内的文件。用户数据在 %LOCALAPPDATA%\com.xingmanxia.app，
  ; 不在 $INSTDIR 下，卸载不会触碰。
  Delete "$INSTDIR\${PRODUCT_EXE}"
  Delete "$INSTDIR\${UNINSTALL_EXE}"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\native_assets.json"
  RMDir /r "$INSTDIR\data"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\星漫匣\星漫匣.lnk"
  Delete "$SMPROGRAMS\星漫匣\卸载星漫匣.lnk"
  RMDir "$SMPROGRAMS\星漫匣"

  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${UNINSTALL_KEY}"
SectionEnd