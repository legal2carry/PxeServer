@echo off
:: FDLTCC Imaging Script - runs from \\10.1.4.245\shared\imaging\
:: Erases disk, applies Windows 11 Pro, configures for unattended OOBE

echo ============================================
echo  FDLTCC - Erasing and Imaging Disk
echo  %date% %time%
echo ============================================

set SHARE=Z:
set WINPE_LOG=X:\imaging.log
set INSTALL_WIM=%SHARE%\images\install.wim

:: Verify image exists
if not exist %INSTALL_WIM% (
    echo ERROR: install.wim not found at %INSTALL_WIM%
    echo Please copy a Windows 11 Pro install.wim to \\10.1.4.245\shared\images\
    pause
    exit /b 1
)

echo [%time%] Starting disk preparation... >> %WINPE_LOG%
echo.
echo Step 1/5: Wiping and partitioning disk 0...
diskpart /s %SHARE%\imaging\diskpart.txt
if errorlevel 1 (
    echo ERROR: diskpart failed.
    echo [%time%] ERROR: diskpart failed >> %WINPE_LOG%
    pause
    exit /b 1
)
echo [%time%] Disk partitioned OK >> %WINPE_LOG%

echo.
echo Step 2/5: Applying Windows 11 Pro image (this takes 5-15 minutes)...
echo [%time%] Starting DISM apply >> %WINPE_LOG%
dism /Apply-Image /ImageFile:%INSTALL_WIM% /Index:1 /ApplyDir:W:\
if errorlevel 1 (
    echo ERROR: DISM apply-image failed.
    echo [%time%] ERROR: DISM failed >> %WINPE_LOG%
    pause
    exit /b 1
)
echo [%time%] DISM apply complete >> %WINPE_LOG%

echo.
echo Step 3/5: Making system bootable...
bcdboot W:\Windows /s S: /f ALL /l en-us
if errorlevel 1 (
    echo ERROR: bcdboot failed.
    echo [%time%] ERROR: bcdboot failed >> %WINPE_LOG%
    pause
    exit /b 1
)
echo [%time%] bcdboot OK >> %WINPE_LOG%

echo.
echo Step 4/5: Copying setup scripts...
mkdir W:\Windows\Setup\Scripts 2>nul
copy /Y %SHARE%\imaging\post-install.ps1 W:\Windows\Setup\Scripts\post-install.ps1
copy /Y %SHARE%\imaging\autounattend.xml W:\unattend.xml
echo [%time%] Scripts copied >> %WINPE_LOG%

echo.
echo Step 5/5: Setting PowerShell execution policy in offline image...
reg load HKLM\TempSoftware W:\Windows\System32\config\SOFTWARE
reg add "HKLM\TempSoftware\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d RemoteSigned /f
reg unload HKLM\TempSoftware
echo [%time%] Execution policy set >> %WINPE_LOG%

echo [%time%] Imaging complete. Rebooting in 10 seconds... >> %WINPE_LOG%
echo.
echo ============================================
echo  Imaging complete! Rebooting in 10 seconds.
echo  Remove PXE / set boot order to disk.
echo ============================================
ping -n 11 127.0.0.1 >nul
wpeutil reboot
