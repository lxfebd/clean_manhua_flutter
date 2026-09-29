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
    ; 锁状态，直接覆盖会失败。给进程退出并释放句柄留时间（2.5s）。
    Sleep 1500
    Sleep 500
    Sleep 500

    ; —— 原子化静默升级 ——
    ; 旧设计是「先 RMDir /r 删掉旧目录，再 File /r 拷新版」：若拷贝中途失败
    ; （磁盘满/断电/杀毒占用），旧版已被删、新版没拷全，应用直接无法启动且无回滚。
    ; 现在改为：1) 新版先完整落到 $INSTDIR.new；2) 把当前目录改名成 $INSTDIR.old；
    ; 3) 新版改名为正式目录；4) 最后才删除旧目录。任何一步失败都保留旧版本。
    SetOutPath "$INSTDIR.new"
    File /r "build\windows\x64\runner\Release\*"
    IfErrors 0 f1_staged
      ; 新版没能写入：清理暂存，保留旧版，中止
      RMDir /r "$INSTDIR.new"
      MessageBox MB_OK|MB_ICONSTOP "升级失败：新版文件写入失败，已保留当前版本。"
      SetErrorLevel 1
      Abort
    f1_staged:

    ; 把旧安装目录改名为 .old 留作备份。目录改名若失败 → 旧 exe 仍被占用，
    ; 说明旧进程还没真正退出；此时不动任何东西、保留旧版。
    Rename "$INSTDIR" "$INSTDIR.old"
    IfErrors 0 f2_old_moved
      MessageBox MB_OK|MB_ICONSTOP "升级失败：应用仍在后台运行，请关闭后可重试。当前版本已保留。"
      RMDir /r "$INSTDIR.new"
      SetErrorLevel 2
      Abort
    f2_old_moved:

    ; 新版改名为正式目录
    Rename "$INSTDIR.new" "$INSTDIR"
    IfErrors 0 f3_new_moved
      ; 改名失败：把旧版换回，丢弃新版暂存，保留旧版可运行
      Rename "$INSTDIR.old" "$INSTDIR"
      RMDir /r "$INSTDIR.new"
      SetErrorLevel 3
      Abort
    f3_new_moved:

    ; 新版已在正式目录，此刻才安全清掉旧目录（即使因占用删不掉，也不影响新版启动）
    RMDir /r "$INSTDIR.old"
  ${else}
    ; 手动安装：直接写并（正式目录可能为空或已有的用户所选目录）。
    ; 用户数据在 %LOCALAPPDATA%\com.xingmanxia.app，不在 $INSTDIR 内，不受影响。
    SetOutPath "$INSTDIR"
    File /r "build\windows\x64\runner\Release\*"
  ${endif}

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