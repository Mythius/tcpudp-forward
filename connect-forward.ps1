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
  [switch]$Refresh,                    # re-download the config even if one is saved
  [switch]$Disconnect,                 # stop the tunnel, keep the saved config
  [switch]$Remove                      # stop the tunnel and delete everything
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this script in an elevated (Administrator) PowerShell." }

$wg = "C:\Program Files\WireGuard\wireguard.exe"
$ruleName = "Game Forward (from server tunnel)"

if ($Disconnect) {
  if (Test-Path $wg) { & $wg /uninstalltunnelservice $TunnelName }
  Write-Host "Disconnected. Run connect.bat to reconnect (saved config kept)."
  return
}

if ($Remove) {
  if (Test-Path $wg) { & $wg /uninstalltunnelservice $TunnelName }
  Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Remove-Item (Join-Path $env:ProgramData "GameForward") -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Disconnected, removed firewall rule and stored config."
  return
}

# Install WireGuard if missing.
if (-not (Test-Path $wg)) {
  Write-Host "Installing WireGuard..."
  winget install --id WireGuard.WireGuard -e --accept-package-agreements --accept-source-agreements
  if (-not (Test-Path $wg)) { throw "WireGuard install failed; install it from wireguard.com and re-run." }
}

# Get the client config.
# The tunnel service runs directly from this file, so it must stay in place.
# Lock the folder to SYSTEM + Administrators because it holds a private key.
$cfgDir = Join-Path $env:ProgramData "GameForward"
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
& icacls $cfgDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
$conf = Join-Path $cfgDir "$TunnelName.conf"   # file name becomes the tunnel name

try {
  if ($ConfigFile) {
    Copy-Item $ConfigFile $conf
  } elseif ((Test-Path $conf) -and -not $Refresh) {
    Write-Host "Using saved config (use -Refresh to re-download from the server)."
  } else {
    if (-not $User) { $User = Read-Host "SSH username for $Server" }
    Write-Host "Fetching config from $User@$Server (you may be prompted for your SSH password and sudo)..."
    # Step 1 (-t gives sudo a terminal to prompt on): copy the root-only config
    # to a private temp file owned by the SSH user.
    $remoteTmp = "/tmp/gameforward-client.conf"
    ssh -t "$User@$Server" "sudo install -m 600 -o `$(id -un) /etc/wireguard/windows-client.conf $remoteTmp"
    if ($LASTEXITCODE -ne 0) {
      throw "Could not read the config on the server. Did you run setup-server.sh, and does '$User' have sudo?"
    }
    # Step 2: download it, then delete the temp copy on the server.
    scp "$User@${Server}:$remoteTmp" $conf
    $scpOk = $LASTEXITCODE -eq 0
    ssh "$User@$Server" "rm -f $remoteTmp"
    if (-not $scpOk -or -not (Select-String -Path $conf -Pattern "\[Interface\]" -Quiet)) {
      throw "Failed to download the config from the server."
    }
  }

  # Reinstall cleanly if already present.
  if (Get-Service "WireGuardTunnel`$$TunnelName" -ErrorAction SilentlyContinue) {
    & $wg /uninstalltunnelservice $TunnelName
    Start-Sleep -Seconds 2
  }
  & $wg /installtunnelservice $conf
}
catch {
  Remove-Item $conf -Force -ErrorAction SilentlyContinue
  throw
}

# Allow forwarded game traffic (it arrives from the server's tunnel IP).
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
  -RemoteAddress 10.66.66.1 -Profile Any | Out-Null

Start-Sleep -Seconds 3
Write-Host "`nTunnel status:"
try { & "C:\Program Files\WireGuard\wg.exe" show $TunnelName } catch { Write-Warning "Tunnel interface not found; check the 'WireGuardTunnel`$$TunnelName' service." }
Write-Host "`nTesting tunnel..."
if (Test-Connection 10.66.66.1 -Count 2 -Quiet) {
  Write-Host "Connected. Start your game server/host on this PC; forwarded ports will reach it."
} else {
  Write-Warning "Cannot reach 10.66.66.1. Check UDP 51820 is open on the server's firewall."
}
