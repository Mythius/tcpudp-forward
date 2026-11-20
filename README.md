# tcpudp-forward

Forward game traffic (TCP and UDP) from a public Ubuntu server to a Windows PC
that sits behind NAT.

```
Players ──> msouthwick.com:<game port> ──(iptables DNAT)──> WireGuard tunnel ──> Windows PC:<game port>
```

The Windows PC dials out to the server and keeps a WireGuard tunnel open, so the
PC itself needs no port forwarding. The server forwards the game ports down that
tunnel.

| File | Runs on | Purpose |
|------|---------|---------|
| `setup-server.sh` | Ubuntu server | Installs WireGuard, sets up the tunnel and iptables forwarding, generates the Windows client config |
| `connect-forward.ps1` | Windows | Installs WireGuard, fetches the client config over SSH, starts the tunnel |
| `connect.bat` / `disconnect.bat` | Windows | Double-click launchers that ask for administrator rights |

## Ports that must be reachable on the server

If the server is behind a home router, forward these on the router to the
server's LAN IP (give the server a static or reserved IP first). If it is a
cloud server, open them in the provider's firewall instead. If the server uses
`ufw`, the setup script opens the WireGuard port itself; open game ports with
`sudo ufw allow <port>` if needed.

| Port | Protocol | Why |
|------|----------|-----|
| **51820** | **UDP** | WireGuard tunnel. Required, or nothing works. |
| Your game ports (e.g. **6567**) | TCP and/or UDP | Whatever you pass to `--tcp` / `--udp` in setup |

Nothing needs to be forwarded on the Windows PC's router.

## Setup

### 1. Server (once)

```bash
sudo ./setup-server.sh --tcp 6567 --udp 6567
```

- Ports are comma-separated, ranges use a colon: `--tcp 7000:7010,25565`.
- `--endpoint` sets the hostname clients connect to (default `msouthwick.com`).
- `--wg-port` changes the WireGuard port (default 51820).
- Re-running is safe: keys are reused and rules are rebuilt. Re-run it to change
  the forwarded ports.
- Undo everything: `sudo ./setup-server.sh --remove`

The script installs WireGuard, enables IP forwarding, writes `/etc/wireguard/wg0.conf`
(the iptables rules are applied whenever the tunnel comes up, so they survive
reboots) and writes the client config to `/etc/wireguard/windows-client.conf`.

### 2. Windows PC

1. Edit `SSH_USER` at the top of `connect.bat` to your SSH username on the server.
2. Double-click `connect.bat` and accept the administrator (UAC) prompt.
3. First run only: it installs WireGuard (via winget) and asks for your SSH
   password and `sudo` password to download the client config. The config is
   saved in `C:\ProgramData\GameForward` (readable only by SYSTEM and
   Administrators). Later runs reuse it and need no passwords.
4. Look for `Connected.` at the end. Start your game server on the PC, listening
   on the same ports you forwarded.

To disconnect, double-click `disconnect.bat`.

Command-line equivalents (elevated PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\connect-forward.ps1 -User <ssh-user>
.\connect-forward.ps1 -Refresh      # re-download the config from the server
.\connect-forward.ps1 -Disconnect   # stop the tunnel, keep config
.\connect-forward.ps1 -Remove       # stop the tunnel, delete config and firewall rule
```

## Using more than one PC

Every PC fetches the same client config (same key, same tunnel IP
`10.66.66.2`), so only one PC can be connected at a time. Run `disconnect.bat`
on one before connecting the other, or the tunnel flips between them and both
break. The SSH account used needs `sudo`.

## Verifying it works

On Windows (elevated):

```powershell
& "C:\Program Files\WireGuard\wg.exe" show gameforward   # want "latest handshake" and received > 0 B
Test-Connection 10.66.66.1                                # should reply
```

On the server: `sudo wg show` (peer should show a recent handshake) and
`sudo iptables -t nat -S PREROUTING` (should list a DNAT rule per game port).

## Troubleshooting

- **No handshake, `0 B received`:** UDP 51820 isn't reaching the server. Check
  the router/cloud forward, the server's LAN IP, and that `msouthwick.com`
  resolves to your router's current public IP. On the server,
  `sudo tcpdump -ni <interface> udp port 51820` shows whether packets arrive.
- **Tunnel is up but players can't connect:** check the game ports are forwarded
  to the server, allowed in `ufw`, and that your game is listening on the PC.
  Windows Defender Firewall may need the game allowed (the script adds a rule
  allowing all inbound traffic from the tunnel IP `10.66.66.1`).
- **Forwarding stops after restarting Docker:** Docker rewrites iptables chains.
  Restart the tunnel with `sudo systemctl restart wg-quick@wg0`.
- **"running scripts is disabled":** use `connect.bat`, or the
  `-ExecutionPolicy Bypass` command above.
- **Service won't start:** see the System event log entries from
  *Service Control Manager* for `WireGuard Tunnel: gameforward`.

## Notes

- The game sees every player as coming from `10.66.66.1` (the server's tunnel
  IP), not their real address. Per-player IP bans won't work.
- Forwarded ports are fixed per server setup and all go to whichever PC is
  connected.
- The client config contains a private key. Share it only with people you trust.
