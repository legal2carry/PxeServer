#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$false)]
    [string]$SharePassword
)
# Run once as Administrator to complete PXE server setup
$ErrorActionPreference = 'Stop'

Write-Host "=== PXE Server Admin Setup ===" -ForegroundColor Cyan

# 1. Configure BCD for network boot
Write-Host "`n[1/6] Configuring BCD for network boot..."
$BcdPath = "C:\PXEServer\tftproot\Boot\BCD"
$RdGuid  = "{7619dcc8-fafe-11d9-b411-000476eba25f}"

# Grant admin full control of the BCD file
icacls $BcdPath /grant "Administrators:F" | Out-Null

bcdedit /store $BcdPath /set "{default}" description "FDLTCC WinPE Imaging"
bcdedit /store $BcdPath /set "{default}" device    "ramdisk=[boot]\Boot\boot.wim,$RdGuid"
bcdedit /store $BcdPath /set "{default}" osdevice  "ramdisk=[boot]\Boot\boot.wim,$RdGuid"
bcdedit /store $BcdPath /set "{default}" systemroot \Windows
bcdedit /store $BcdPath /set "{default}" detecthal yes
bcdedit /store $BcdPath /set $RdGuid ramdisksdipath \Boot\boot.sdi
Write-Host "BCD configured." -ForegroundColor Green

# 2. Create 'info' local user
Write-Host "`n[2/6] Creating local user 'info'..."
if ($SharePassword) {
    $pw = ConvertTo-SecureString $SharePassword -AsPlainText -Force
} else {
    $pw = Read-Host "Password for local 'info' account" -AsSecureString
}
try {
    New-LocalUser -Name "info" -Password $pw -PasswordNeverExpires $true `
        -UserMayNotChangePassword $true -Description "PXE imaging share account"
    Write-Host "User 'info' created." -ForegroundColor Green
} catch {
    Set-LocalUser -Name "info" -Password $pw -PasswordNeverExpires $true
    Write-Host "User 'info' updated (already existed)." -ForegroundColor Yellow
}

# 3. Create SMB share
Write-Host "`n[3/6] Creating SMB share 'shared' -> C:\shared..."
try {
    New-SmbShare -Name "shared" -Path "C:\shared" -FullAccess "info"
    Write-Host "Share created." -ForegroundColor Green
} catch {
    Grant-SmbShareAccess -Name "shared" -AccountName "info" -AccessRight Full -Force
    Write-Host "Share already existed - permissions updated." -ForegroundColor Yellow
}

# NTFS permissions on C:\shared
$acl  = Get-Acl "C:\shared"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "info","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$acl.SetAccessRule($rule)
Set-Acl "C:\shared" $acl
Write-Host "NTFS permissions set." -ForegroundColor Green

# 4. Deploy tftpd64 config
Write-Host "`n[4/6] Deploying tftpd64 config..."
Copy-Item "C:\projects\PxeServer\tftpd64\tftpd32.ini" `
          "C:\Program Files\Tftpd64\tftpd32.ini" -Force
Write-Host "tftpd32.ini deployed." -ForegroundColor Green

# 5. Start tftpd64
Write-Host "`n[5/6] Starting tftpd64..."
$tftpProc = Get-Process tftpd64 -ErrorAction SilentlyContinue
if ($tftpProc) {
    Write-Host "tftpd64 already running (PID $($tftpProc.Id))." -ForegroundColor Yellow
} else {
    Start-Process "C:\Program Files\Tftpd64\tftpd64.exe"
    Start-Sleep 2
    $tftpProc = Get-Process tftpd64 -ErrorAction SilentlyContinue
    if ($tftpProc) {
        Write-Host "tftpd64 started (PID $($tftpProc.Id))." -ForegroundColor Green
    } else {
        Write-Host "WARNING: tftpd64 did not start - launch manually." -ForegroundColor Red
    }
}

# 6. Start DHCP proxy
Write-Host "`n[6/6] Starting DHCP proxy..."
$dhcpProc = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'dhcp_proxy' }
if ($dhcpProc) {
    Write-Host "DHCP proxy already running (PID $($dhcpProc.ProcessId))." -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force "C:\PXEServer" | Out-Null
    Start-Process powershell -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\projects\PxeServer\dhcp_proxy.ps1"
    Start-Sleep 2
    $dhcpProc = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'dhcp_proxy' }
    if ($dhcpProc) {
        Write-Host "DHCP proxy started (PID $($dhcpProc.ProcessId))." -ForegroundColor Green
    } else {
        Write-Host "WARNING: DHCP proxy did not start." -ForegroundColor Red
    }
}

# Verify ports
Write-Host "`n=== Port Check ===" -ForegroundColor Cyan
$ports = netstat -ano | Select-String ":67 |:69 "
if ($ports) { $ports } else { Write-Host "WARNING: Neither :67 nor :69 is listening yet." -ForegroundColor Red }

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "TFTP root: C:\PXEServer\tftproot"
Write-Host "Share:     \\$env:COMPUTERNAME\shared -> C:\shared"
Write-Host "Log:       C:\PXEServer\dhcp_proxy.log"
