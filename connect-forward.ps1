<#
.SYNOPSIS
  Connects this Windows PC to the forwarding server (msouthwick.com).

.DESCRIPTION
  Installs WireGuard if needed, fetches the client config that setup-server.sh
  generated on the server (over SSH, or from a local file), and starts the
  tunnel as a Windows service. Traffic the server forwards then arrives here on
  the same ports. Run from an elevated (Administrator) PowerShell.

.EXAMPLE
  .\connect-forward.ps1 -User ubuntu
  .\connect-forward.ps1 -ConfigFile C:\path\windows-client.conf
  .\connect-forward.ps1 -Remove
#>
[CmdletBinding()]
param(
  [string]$Server = "msouthwick.com",
  [string]$User,                       # SSH user on the server (needs sudo)
  [string]$ConfigFile,                 # use a local config instead of SSH
  [string]$TunnelName = "gameforward",
  [switch]$Remove
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this script in an elevated (Administrator) PowerShell." }

$wg = "C:\Program Files\WireGuard\wireguard.exe"
$ruleName = "Game Forward (from server tunnel)"

if ($Remove) {
  if (Test-Path $wg) { & $wg /uninstalltunnelservice $TunnelName }
  Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Write-Host "Disconnected and removed firewall rule."
  return
}

# Install WireGuard if missing.
if (-not (Test-Path $wg)) {
  Write-Host "Installing WireGuard..."
  winget install --id WireGuard.WireGuard -e --accept-package-agreements --accept-source-agreements
  if (-not (Test-Path $wg)) { throw "WireGuard install failed; install it from wireguard.com and re-run." }
}

# Get the client config.
$tmpDir = Join-Path $env:TEMP "gameforward-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$conf = Join-Path $tmpDir "$TunnelName.conf"   # file name becomes the tunnel name

try {
  if ($ConfigFile) {
    Copy-Item $ConfigFile $conf
  } else {
    if (-not $User) { $User = Read-Host "SSH username for $Server" }
    Write-Host "Fetching config from $User@$Server (you may be prompted for your SSH password and sudo)..."
    # -t allows a sudo password prompt; output is captured to the file.
    $text = ssh "$User@$Server" "sudo cat /etc/wireguard/windows-client.conf"
    if ($LASTEXITCODE -ne 0 -or -not ($text -match "\[Interface\]")) {
      throw "Could not fetch config. Did you run setup-server.sh on the server?"
    }
    $text | Set-Content -Path $conf -Encoding ascii
  }

  # Reinstall cleanly if already present.
  if (Get-Service "WireGuardTunnel`$$TunnelName" -ErrorAction SilentlyContinue) {
    & $wg /uninstalltunnelservice $TunnelName
    Start-Sleep -Seconds 2
  }
  & $wg /installtunnelservice $conf
}
finally {
  # WireGuard stores its own encrypted copy; don't leave the private key in TEMP.
  Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Allow forwarded game traffic (it arrives from the server's tunnel IP).
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
  -RemoteAddress 10.66.66.1 -Profile Any | Out-Null

Start-Sleep -Seconds 3
Write-Host "`nTunnel status:"
& "C:\Program Files\WireGuard\wg.exe" show $TunnelName 2>$null
Write-Host "`nTesting tunnel..."
if (Test-Connection 10.66.66.1 -Count 2 -Quiet) {
  Write-Host "Connected. Start your game server/host on this PC; forwarded ports will reach it."
} else {
  Write-Warning "Cannot reach 10.66.66.1. Check UDP 51820 is open on the server's firewall."
}
