@echo off
setlocal
set "VSDIR=C:\Program Files\Microsoft Visual Studio\18\Community"
call "%VSDIR%\Common7\Tools\VsDevCmd.bat" -arch=amd64 || exit /b 1
set "PATH=%VSDIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VSDIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
ninja -C "E:\cva6\riscv-compilers\ldc2-build" druntime-ldc phobos2-ldc
exit /b %ERRORLEVEL%
