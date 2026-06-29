# Build WinPE image for FDLTCC PXE imaging pipeline
# Run on the PXE server (10.1.4.245) after ADK + WinPE add-on are installed
# Prerequisites: Windows ADK + WinPE add-on installed

$ErrorActionPreference = 'Stop'
$ADKRoot = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$WinPERoot = "$ADKRoot\Windows Preinstallation Environment"
$DeployRoot = "$ADKRoot\Deployment Tools"
$CopypePath = "$WinPERoot\copype.cmd"
$DandIEnv = "$DeployRoot\DandISetEnv.bat"

$WorkDir = "C:\WinPE_amd64"
$TftpRoot = "C:\PXEServer\tftproot"
$ShareImaging = "C:\shared\imaging"

Write-Host "=== FDLTCC WinPE Build Script ===" -ForegroundColor Cyan

# Verify prerequisites
if (-not (Test-Path $CopypePath)) {
    throw "copype.cmd not found at $CopypePath. Install WinPE add-on first."
}
if (-not (Test-Path $DandIEnv)) {
    throw "DandISetEnv.bat not found at $DandIEnv. Install ADK Deployment Tools first."
}

# Clean previous build
if (Test-Path $WorkDir) {
    Write-Host "Removing previous WinPE build..."
    Remove-Item $WorkDir -Recurse -Force
}

# Create WinPE working directory
Write-Host "Running copype.cmd..."
$env:Path = "$DeployRoot\amd64;$WinPERoot;$env:Path"
cmd /c "`"$DandIEnv`" && `"$CopypePath`" amd64 `"$WorkDir`""

if (-not (Test-Path "$WorkDir\media\sources\boot.wim")) {
    throw "copype.cmd failed - boot.wim not found"
}
Write-Host "WinPE base created at $WorkDir"

# Mount boot.wim for customization
$MountDir = "C:\WinPE_mount"
New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
Write-Host "Mounting boot.wim..."
Mount-WindowsImage -ImagePath "$WorkDir\media\sources\boot.wim" -Index 1 -Path $MountDir

try {
    # Add optional components for networking and scripting
    Write-Host "Adding WinPE optional components..."
    $OcPath = "$WinPERoot\amd64\WinPE_OCs"
    $AddOC = { param($name)
        Add-WindowsPackage -Path $MountDir -PackagePath "$OcPath\$name.cab" -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path "$OcPath\en-us\${name}_en-us.cab") {
            Add-WindowsPackage -Path $MountDir -PackagePath "$OcPath\en-us\${name}_en-us.cab" -ErrorAction SilentlyContinue | Out-Null
        }
    }
    & $AddOC "WinPE-WMI"
    & $AddOC "WinPE-NetFX"
    & $AddOC "WinPE-Scripting"
    & $AddOC "WinPE-PowerShell"
    & $AddOC "WinPE-StorageWMI"
    & $AddOC "WinPE-DismCmdlets"

    # Copy startnet.cmd into the WinPE image
    Write-Host "Installing startnet.cmd..."
    Copy-Item -Path "C:\shared\imaging\startnet.cmd" `
              -Destination "$MountDir\Windows\System32\startnet.cmd" -Force

    # Embed share password (imaging/share.pw, gitignored) so startnet.cmd can mount without prompting
    $SharePwFile = "$PSScriptRoot\share.pw"
    if (Test-Path $SharePwFile) {
        Copy-Item -Path $SharePwFile -Destination "$MountDir\share.pw" -Force
        Write-Host "share.pw embedded in WinPE image."
    } else {
        Write-Warning "imaging\share.pw not found - WinPE will prompt for password at boot. Create it from share.pw.example."
    }

    Write-Host "Components added successfully."
} finally {
    # Unmount and commit
    Write-Host "Unmounting and committing boot.wim..."
    Dismount-WindowsImage -Path $MountDir -Save
    Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Copy WinPE TFTP files to tftproot
Write-Host "Copying WinPE boot files to tftproot..."
$BootDir = "$TftpRoot\Boot"
New-Item -ItemType Directory -Path $BootDir -Force | Out-Null
New-Item -ItemType Directory -Path "$TftpRoot\sources" -Force | Out-Null

# UEFI boot files - bootx64.efi is in EFI\Boot\ in modern WinPE
Copy-Item -Path "$WorkDir\media\bootmgr.efi" -Destination "$TftpRoot\Boot\bootmgr.efi" -Force -ErrorAction SilentlyContinue
Copy-Item -Path "$WorkDir\media\EFI\Boot\bootx64.efi" -Destination "$TftpRoot\Boot\bootx64.efi" -Force

# Boot support files
Copy-Item -Path "$WorkDir\media\Boot\boot.sdi" -Destination "$TftpRoot\Boot\boot.sdi" -Force
Copy-Item -Path "$WorkDir\media\Boot\BCD" -Destination "$TftpRoot\Boot\BCD" -Force
Copy-Item -Path "$WorkDir\media\sources\boot.wim" -Destination "$TftpRoot\Boot\boot.wim" -Force

# Configure BCD for network boot with correct paths
Write-Host "Configuring BCD for network boot..."
$BcdPath = "$TftpRoot\Boot\BCD"
$RdGuid  = "{7619dcc8-fafe-11d9-b411-000476eba25f}"
bcdedit /store $BcdPath /set "{default}" description "FDLTCC WinPE Imaging"
bcdedit /store $BcdPath /set "{default}" device    "ramdisk=[boot]\Boot\boot.wim,$RdGuid"
bcdedit /store $BcdPath /set "{default}" osdevice  "ramdisk=[boot]\Boot\boot.wim,$RdGuid"
bcdedit /store $BcdPath /set "{default}" systemroot \Windows
bcdedit /store $BcdPath /set "{default}" detecthal yes
bcdedit /store $BcdPath /set $RdGuid ramdisksdipath \Boot\boot.sdi

Write-Host ""
Write-Host "=== WinPE Build Complete ===" -ForegroundColor Green
Write-Host "TFTP boot files:"
Get-ChildItem "$TftpRoot\Boot" | Select-Object Name, @{N='MB';E={[math]::Round($_.Length/1MB,1)}} | Format-Table -AutoSize
Write-Host ""
Write-Host "DHCP proxy serves Boot/bootx64.efi for UEFI clients automatically."
Write-Host "PXE boot a test machine to verify WinPE loads."
