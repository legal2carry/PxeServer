param()
$ErrorActionPreference = 'Continue'
$log = 'C:\PXEServer\dhcp_proxy.log'
function Write-Log($msg) {
    "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Add-Content -Path $log
}
Write-Log "DHCP Proxy starting"
$serverIP   = [byte[]](10,1,4,245)
$bootBIOS   = [System.Text.Encoding]::ASCII.GetBytes('pxelinux.0')
$bootUEFI   = [System.Text.Encoding]::ASCII.GetBytes('Boot/bootx64.efi')
$pxeClient  = [System.Text.Encoding]::ASCII.GetBytes('PXEClient')
$sock = New-Object System.Net.Sockets.Socket(
    [System.Net.Sockets.AddressFamily]::InterNetwork,
    [System.Net.Sockets.SocketType]::Dgram,
    [System.Net.Sockets.ProtocolType]::Udp)
$sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,[System.Net.Sockets.SocketOptionName]::ReuseAddress,$true)
$sock.EnableBroadcast = $true
$sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,67))
Write-Log "Listening on 0.0.0.0:67 (BIOS→pxelinux.0 | UEFI→Boot/bootx64.efi)"
$buf = [byte[]]::new(1500)
$ep  = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0))
while ($true) {
    try {
        $recv = $sock.ReceiveFrom($buf,[ref]$ep)
        if ($recv -lt 240) { continue }
        if ($buf[0] -ne 1) { continue }
        if ($buf[236] -ne 99 -or $buf[237] -ne 130 -or $buf[238] -ne 83 -or $buf[239] -ne 99) { continue }
        $isPXE = $false
        $clientArch = 0   # 0=BIOS x86, 6=UEFI ia32, 7=UEFI x64, 9=UEFI x64 (alt)
        $i = 240
        while ($i -lt ($recv - 1)) {
            $opt = $buf[$i]
            if ($opt -eq 255) { break }
            if ($opt -eq 0) { $i++; continue }
            $l = $buf[$i+1]
            if (($i + 2 + $l) -gt $recv) { break }
            # Option 60: vendor class - detect PXEClient
            if ($opt -eq 60 -and $l -ge 9) {
                if ([System.Text.Encoding]::ASCII.GetString($buf,$i+2,9) -eq 'PXEClient') { $isPXE = $true }
            }
            # Option 93: client system architecture (0=BIOS, 7=UEFI x64)
            if ($opt -eq 93 -and $l -eq 2) {
                $clientArch = ($buf[$i+2] -shl 8) -bor $buf[$i+3]
            }
            $i += 2 + $l
        }
        if (-not $isPXE) { continue }
        # Select boot file: UEFI if arch 6,7,9; BIOS otherwise
        $isUEFI = ($clientArch -eq 6 -or $clientArch -eq 7 -or $clientArch -eq 9)
        $bootFile = if ($isUEFI) { $bootUEFI } else { $bootBIOS }
        $archLabel = if ($isUEFI) { "UEFI" } else { "BIOS" }
        Write-Log "PXE DISCOVER from $ep arch=$clientArch ($archLabel) → $([System.Text.Encoding]::ASCII.GetString($bootFile))"
        $r = [byte[]]::new(350)
        $r[0]=2; $r[1]=$buf[1]; $r[2]=$buf[2]; $r[3]=0
        [Array]::Copy($buf,4,$r,4,4)
        [Array]::Copy($serverIP,0,$r,20,4)
        [Array]::Copy($buf,28,$r,28,16)
        $sn=[System.Text.Encoding]::ASCII.GetBytes('10.1.4.245')
        [Array]::Copy($sn,0,$r,44,$sn.Length)
        [Array]::Copy($bootFile,0,$r,108,[Math]::Min($bootFile.Length,128))
        $r[236]=99;$r[237]=130;$r[238]=83;$r[239]=99
        $p=240
        $r[$p++]=53;$r[$p++]=1;$r[$p++]=5
        $r[$p++]=54;$r[$p++]=4;$r[$p++]=10;$r[$p++]=1;$r[$p++]=4;$r[$p++]=245
        $r[$p++]=60;$r[$p++]=$pxeClient.Length;$pxeClient|ForEach-Object{$r[$p++]=$_}
        $r[$p++]=66;$r[$p++]=$sn.Length;$sn|ForEach-Object{$r[$p++]=$_}
        $r[$p++]=67;$r[$p++]=$bootFile.Length;$bootFile|ForEach-Object{$r[$p++]=$_}
        $r[$p++]=255
        $dest=[System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast,68)
        $sent=$sock.SendTo($r,$p,[System.Net.Sockets.SocketFlags]::None,$dest)
        Write-Log "Sent proxy DHCP ($sent bytes) → boot=$([System.Text.Encoding]::ASCII.GetString($bootFile))"
    } catch {
        Write-Log "Error: $($_.Exception.Message)"
    }
}
