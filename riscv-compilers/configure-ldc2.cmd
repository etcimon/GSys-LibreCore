@echo off
setlocal
set "VSDIR=C:\Program Files\Microsoft Visual Studio\18\Community"
call "%VSDIR%\Common7\Tools\VsDevCmd.bat" -arch=amd64 || exit /b 1
set "PATH=%VSDIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VSDIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
set "LLVM_ROOT=E:\cva6\riscv-compilers\toolchains\llvm-22.1.8-windows-x64"
set "HOST_LDMD=E:\cva6\riscv-compilers\toolchains\ldc2-1.42.0-windows-x64\bin\ldmd2.exe"
set "SRC=E:\cva6\riscv-compilers\ldc2"
set "BLD=E:\cva6\riscv-compilers\ldc2-build"
if not exist "%BLD%" mkdir "%BLD%"
cmake -G Ninja -S "%SRC%" -B "%BLD%" -DCMAKE_BUILD_TYPE=Release -DLLVM_ROOT_DIR="%LLVM_ROOT%" -DD_COMPILER="%HOST_LDMD%" -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
exit /b %ERRORLEVEL%
