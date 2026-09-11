@echo off
rem M3 demo .so cross compile (Windows + NDK clang).
rem usage: build_android_so.bat <ndk_root>  e.g. J:/smter/smart/smart/android-sdk/ndk/28.2.13676358
rem output: libdemo_math.so per ABI dir (arm64-v8a/armeabi-v7a/x86_64)
rem         for jniLibs bundling (build-time; Android forbids runtime dlopen).
setlocal
set "NDK=%~1"
if "%NDK%"=="" (
  echo usage: %~nx0 ^<ndk_root^>
  exit /b 1
)
set "BIN=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin"
set "OUT=%~dp0android\libdemo_math\jni"
set "SRC=%~dp0demo_math_android.c"

if not exist "%OUT%" mkdir "%OUT%"
mkdir "%OUT%\arm64-v8a" 2>nul
mkdir "%OUT%\armeabi-v7a" 2>nul
mkdir "%OUT%\x86_64" 2>nul

echo === arm64-v8a ===
"%BIN%\aarch64-linux-android24-clang.cmd" -shared -fPIC -O2 -o "%OUT%\arm64-v8a\libdemo_math.so" "%SRC%" || exit /b 1

echo === armeabi-v7a ===
"%BIN%\armv7a-linux-androideabi24-clang.cmd" -shared -fPIC -O2 -o "%OUT%\armeabi-v7a\libdemo_math.so" "%SRC%" || exit /b 1

echo === x86_64 ===
"%BIN%\x86_64-linux-android24-clang.cmd" -shared -fPIC -O2 -o "%OUT%\x86_64\libdemo_math.so" "%SRC%" || exit /b 1

echo done. artifacts:
dir /s /b "%OUT%\*.so"
endlocal
