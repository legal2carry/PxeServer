#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$false)]
    [string]$SharePassword,

    [switch]$SkipStaticIP,
    [string]$InterfaceAlias = "Ethernet",
    [string]$StaticIP       = "10.1.4.245",
    [int]$PrefixLength      = 24,
    [string]$Gateway        = "10.1.4.254",
    [string[]]$DnsServers   = @("199.17.243.243","10.3.1.220","10.0.1.220","199.17.241.241")
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

# 4. Install tftpd64 as a Windows service (Tftpd64 Service Edition)
Write-Host "`n[4/6] Installing tftpd64 as a Windows service..."
$TftpInstallDir = "C:\Program Files\Tftpd64-SVC"
$TftpServiceExe = "$TftpInstallDir\tftpd64_svc.exe"
$TftpServiceName = "Tftpd32_svc"

if (-not (Test-Path $TftpServiceExe)) {
    Start-Process -FilePath "C:\PXEServer\Tftpd64_Service_Installer.exe" -ArgumentList "/S" -Wait
    Start-Sleep -Seconds 2
}
if (-not (Get-Service -Name $TftpServiceName -ErrorAction SilentlyContinue)) {
    & $TftpServiceExe -install
    Start-Sleep -Seconds 2
}

# Deploy the proven tftpd32.ini config (source of truth lives in this repo)
Copy-Item "C:\projects\PxeServer\tftpd64\tftpd32.ini" "$TftpInstallDir\tftpd32.ini" -Force

# Stop any old bare tftpd64.exe process so it doesn't collide with the service on UDP 69
Get-Process -Name "tftpd64","tftpd64_svc" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -ne $TftpServiceExe } |
    Stop-Process -Force -ErrorAction SilentlyContinue

Set-Service -Name $TftpServiceName -StartupType Automatic
Start-Service -Name $TftpServiceName -ErrorAction SilentlyContinue
sc.exe failure $TftpServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Write-Host "tftpd64 service '$TftpServiceName' installed and running." -ForegroundColor Green

# 5. Persist DHCP proxy via Scheduled Task
Write-Host "`n[5/6] Persisting DHCP proxy via Scheduled Task..."
Get-NetUDPEndpoint -LocalPort 67 -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$action    = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -WindowStyle Hidden -File C:\PXEServer\dhcp_proxy.ps1" `
             -WorkingDirectory "C:\PXEServer"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest -LogonType ServiceAccount
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 999 `
             -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "PXE-DHCPProxy" -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName "PXE-DHCPProxy"
Write-Host "Scheduled task 'PXE-DHCPProxy' registered and started." -ForegroundColor Green

# 6. Convert network adapter to a static IP matching the current DHCP lease
if ($SkipStaticIP) {
    Write-Host "`n[6/6] Skipping static IP conversion (-SkipStaticIP)." -ForegroundColor Yellow
} else {
    Write-Host "`n[6/6] Converting '$InterfaceAlias' to static IP $StaticIP/$PrefixLength..."
    $current = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($current -and $current.PrefixOrigin -eq 'Manual' -and $current.IPAddress -eq $StaticIP) {
        Write-Host "Already static at $StaticIP - skipping." -ForegroundColor Yellow
    } else {
        Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $StaticIP -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DnsServers
        Write-Host "Static IP configured." -ForegroundColor Green
        Write-Host "NOTE: request a DHCP exclusion/reservation for $StaticIP from whoever manages the campus DHCP server, so it doesn't get handed to another device." -ForegroundColor Yellow
    }
}

# Verify ports
Write-Host "`n=== Port Check ===" -ForegroundColor Cyan
$ports = netstat -ano | Select-String ":67 |:69 "
if ($ports) { $ports } else { Write-Host "WARNING: Neither :67 nor :69 is listening yet." -ForegroundColor Red }

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "TFTP root: C:\PXEServer\tftproot"
Write-Host "TFTP service: $TftpServiceName ($TftpInstallDir)"
Write-Host "DHCP proxy task: PXE-DHCPProxy"
Write-Host "Share:     \\$env:COMPUTERNAME\shared -> C:\shared"
Write-Host "Log:       C:\PXEServer\dhcp_proxy.log"
