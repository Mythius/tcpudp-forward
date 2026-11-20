#!/usr/bin/env bash
# Run on the Ubuntu server (msouthwick.com) as root.
#
# Creates a WireGuard tunnel (wg0, 10.66.66.1) and iptables rules that forward
# the chosen TCP/UDP ports arriving on the server's public interface through the
# tunnel to your Windows PC (10.66.66.2). Also writes the Windows client config
# to /etc/wireguard/windows-client.conf (used by connect-forward.ps1).
#
# Usage:
#   sudo ./setup-server.sh --tcp 25565 --udp 25565,19132
#   sudo ./setup-server.sh --tcp 7000:7010 --udp 7000:7010 --endpoint msouthwick.com
#
# Ports are comma-separated; ranges use a colon (7000:7010).
# Re-running is safe: keys are reused and the rules are rebuilt.
# Remove everything:  sudo ./setup-server.sh --remove
set -euo pipefail

TCP_PORTS=""
UDP_PORTS=""
ENDPOINT="msouthwick.com"
WG_PORT=51820
WAN_IF=""
WG_IF="wg0"
SERVER_IP="10.66.66.1"
CLIENT_IP="10.66.66.2"
REMOVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tcp) TCP_PORTS="$2"; shift 2 ;;
    --udp) UDP_PORTS="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --wg-port) WG_PORT="$2"; shift 2 ;;
    --iface) WAN_IF="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

if [[ $REMOVE -eq 1 ]]; then
  systemctl disable --now "wg-quick@${WG_IF}" 2>/dev/null || true
  rm -f "/etc/wireguard/${WG_IF}.conf" /etc/wireguard/windows-client.conf \
        /etc/wireguard/${WG_IF}-*.key /etc/sysctl.d/99-game-forward.conf
  echo "Removed tunnel, keys and forwarding rules."
  exit 0
fi

[[ -n "$TCP_PORTS$UDP_PORTS" ]] || { echo "Specify at least one of --tcp / --udp." >&2; exit 1; }
for p in ${TCP_PORTS//,/ } ${UDP_PORTS//,/ }; do
  [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]] || { echo "Bad port spec: $p" >&2; exit 1; }
done
[[ "$TCP_PORTS$UDP_PORTS" != *"$WG_PORT"* ]] || echo "Warning: a game port overlaps the WireGuard port $WG_PORT." >&2

# Detect the public interface.
if [[ -z "$WAN_IF" ]]; then
  WAN_IF="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
[[ -n "$WAN_IF" ]] || { echo "Could not detect public interface; pass --iface." >&2; exit 1; }
echo "Public interface: $WAN_IF"

# Install WireGuard.
if ! command -v wg >/dev/null; then
  apt-get update -y
  apt-get install -y wireguard iptables
fi

# Enable IPv4 forwarding permanently.
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-game-forward.conf
sysctl -q -p /etc/sysctl.d/99-game-forward.conf

# Keys (reused on re-run).
umask 077
mkdir -p /etc/wireguard
K=/etc/wireguard/${WG_IF}
[[ -f $K-server.key ]] || wg genkey > $K-server.key
[[ -f $K-client.key ]] || wg genkey > $K-client.key
SERVER_PRIV="$(cat $K-server.key)"; SERVER_PUB="$(wg pubkey < $K-server.key)"
CLIENT_PRIV="$(cat $K-client.key)"; CLIENT_PUB="$(wg pubkey < $K-client.key)"

# Build iptables rules (applied on tunnel up, removed on tunnel down).
UP=(); DOWN=()
add_rule() { # table-and-chain-args...
  UP+=("iptables -A $*"); DOWN+=("iptables -D $*")
}
ins_rule() {
  UP+=("iptables -I $*"); DOWN+=("iptables -D ${*/ 1 / }")
}
# Return traffic from the PC.
ins_rule "FORWARD 1 -i ${WG_IF} -o ${WAN_IF} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
for proto in tcp udp; do
  [[ $proto == tcp ]] && PORTS="$TCP_PORTS" || PORTS="$UDP_PORTS"
  for p in ${PORTS//,/ }; do
    # No port in --to-destination keeps the same port (also works for ranges).
    add_rule "PREROUTING -t nat -i ${WAN_IF} -p ${proto} --dport ${p} -j DNAT --to-destination ${CLIENT_IP}"
    ins_rule "FORWARD 1 -i ${WAN_IF} -o ${WG_IF} -d ${CLIENT_IP} -p ${proto} --dport ${p} -j ACCEPT"
  done
done
# Make replies come back through the server (the game sees clients as 10.66.66.1).
add_rule "POSTROUTING -t nat -o ${WG_IF} -d ${CLIENT_IP} -j MASQUERADE"

{
  echo "[Interface]"
  echo "Address = ${SERVER_IP}/24"
  echo "ListenPort = ${WG_PORT}"
  echo "PrivateKey = ${SERVER_PRIV}"
  for r in "${UP[@]}";   do echo "PostUp = $r";   done
  for r in "${DOWN[@]}"; do echo "PostDown = $r"; done
  echo
  echo "[Peer]"
  echo "PublicKey = ${CLIENT_PUB}"
  echo "AllowedIPs = ${CLIENT_IP}/32"
} > /etc/wireguard/${WG_IF}.conf

cat > /etc/wireguard/windows-client.conf <<EOF
[Interface]
Address = ${CLIENT_IP}/32
PrivateKey = ${CLIENT_PRIV}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = ${SERVER_IP}/32
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/*.conf

# Open the WireGuard port if ufw is active.
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "${WG_PORT}/udp"
fi

systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"

echo
echo "Done. Forwarding TCP [${TCP_PORTS:-none}] and UDP [${UDP_PORTS:-none}] -> Windows PC via ${WG_IF}."
echo "Make sure your cloud/provider firewall allows UDP ${WG_PORT} plus the game ports."
echo "Windows client config: /etc/wireguard/windows-client.conf"
iptables -t nat -S PREROUTING
