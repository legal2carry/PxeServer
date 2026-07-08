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

:: Allow guest/anonymous SMB2-3 sessions in this WinPE session - blocked by default on modern
:: Windows clients. Only affects this ephemeral boot session's own registry, not the server.
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f >nul

:: Mount the read-only, anonymous imaging share (no credentials needed)
echo Mounting imaging share...
net use Z: \\10.1.4.245\pxeimaging /persistent:no
if errorlevel 1 (
    echo ERROR: Could not mount share. Retrying in 10 seconds...
    ping -n 11 127.0.0.1 >nul
    net use Z: \\10.1.4.245\pxeimaging /persistent:no
)
if errorlevel 1 (
    echo FATAL: Could not mount \\10.1.4.245\pxeimaging
    echo Check network connection and server status.
    pause
    exit /b 1
)

echo Share mounted successfully.
echo Starting imaging process...

:: Run the imaging script from the share
call Z:\image-machine.cmd
