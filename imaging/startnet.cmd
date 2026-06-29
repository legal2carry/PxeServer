@echo off
:: WinPE startup script - embedded in boot.wim
:: Called automatically by Windows PE environment initialization

echo ============================================
echo  FDLTCC Imaging - PXE Boot
echo ============================================

:: Initialize network and hardware
wpeinit

:: Wait for network to come up
echo Waiting for network...
ping -n 6 127.0.0.1 >nul

:: Mount the imaging share
:: Password read from share.pw embedded in WinPE image by build-winpe.ps1 (not in git)
echo Mounting imaging share...
if exist X:\share.pw (
    set /p SHAREPW=<X:\share.pw
) else (
    set /p SHAREPW=Enter imaging share password:
)
net use Z: \\10.1.4.245\shared /user:info %SHAREPW% /persistent:no
if errorlevel 1 (
    echo ERROR: Could not mount share. Retrying in 10 seconds...
    ping -n 11 127.0.0.1 >nul
    net use Z: \\10.1.4.245\shared /user:info %SHAREPW% /persistent:no
)
if errorlevel 1 (
    echo FATAL: Could not mount \\10.1.4.245\shared
    echo Check network connection and server status.
    pause
    exit /b 1
)

echo Share mounted successfully.
echo Starting imaging process...

:: Run the imaging script from the share
call Z:\imaging\image-machine.cmd
