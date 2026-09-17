#!/usr/bin/env bash
# Splendor Multiplayer — `splendor` turns this laptop into the whole party:
# wifi hotspot up, QR codes for friends, race lobby running, game open.
#
#   splendor [--no-hotspot] [--no-game] [HTTP_PORT] [extra mp_server args...]
#
#   --no-hotspot   stay on the current network (home wifi — no hotspot needed)
#   --no-game      run the lobby only, don't open the game window
#   extra args     pass through to mp_server.gd, e.g. --dist=10000
#
# Friends scan the wifi QR to join the hotspot, then open the game link —
# or scan the second QR. Nobody types anything.
set -euo pipefail
cd "$(dirname "$0")/.."

# Double-clicked from a launcher? Re-run inside a terminal so the QR codes,
# join address and lobby log stay visible.
if [[ ! -t 0 && -z "${SPLENDOR_MP_TERM:-}" ]]; then
	export SPLENDOR_MP_TERM=1
	for term in ghostty alacritty kitty foot xterm; do
		if command -v "$term" >/dev/null 2>&1; then
			case "$term" in
				kitty|foot) exec "$term" "$0" "$@" ;;
				*) exec "$term" -e "$0" "$@" ;;
			esac
		fi
	done
	echo "splendor: no terminal emulator found — run this from a shell" >&2
	exit 1
fi

http=8000
web="build/web"
want_hotspot=1
want_game=1
while [[ $# -gt 0 ]]; do
	case "$1" in
		--no-hotspot) want_hotspot=0 ;;
		--no-game) want_game=0 ;;
		*) break ;;
	esac
	shift
done
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then http="$1"; shift; fi
ws=$((http + 1))

if [[ ! -f "$web/index.html" ]]; then
	echo ">> no web build at $web — exporting (needs Godot export templates)…"
	if ! godot --headless --path . --export-release "Web" "$web/index.html"; then
		echo "!! export failed — friends will get a 404. Install the 4.7.2 templates and re-run."
	fi
fi

# ------------------------------------------------------------- hotspot ----

ssid="splendor"
pass="splendor123"
hotspot_up=0
made_hotspot=0
server_pid=""
game_pid=""

cleanup() {
	[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
	[[ -n "$game_pid" ]] && kill "$game_pid" 2>/dev/null || true
	if [[ "$made_hotspot" == 1 ]]; then
		nmcli connection delete Hotspot >/dev/null 2>&1 || true
		echo ">> hotspot down — wifi back to normal"
	fi
}
trap cleanup EXIT

wifi_if=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
if [[ "$want_hotspot" == 1 && -n "$wifi_if" ]]; then
	active_ssid=$(nmcli -t -f 802-11-wireless.ssid con show Hotspot 2>/dev/null | cut -d: -f2- || true)
	if nmcli -t -f NAME con show --active 2>/dev/null | grep -qx "Hotspot" && [[ "$active_ssid" == "$ssid" ]]; then
		hotspot_up=1
		echo ">> hotspot '$ssid' already up — reusing it"
	elif nmcli -t -f NAME con show --active 2>/dev/null | grep -qx "Hotspot"; then
		echo ">> a hotspot ('$active_ssid') is already running — using it"
	else
		echo ">> starting hotspot '$ssid' (this laptop drops off the internet — the game is all local)"
		if nmcli dev wifi hotspot ifname "$wifi_if" ssid "$ssid" password "$pass" >/dev/null 2>&1; then
			made_hotspot=1
			hotspot_up=1
			for _ in {1..10}; do
				ip -4 addr show dev "$wifi_if" | grep -q 'inet ' && break
				sleep 0.5
			done
		elif ! command -v dnsmasq >/dev/null 2>&1; then
			# NM's shared mode needs dnsmasq to hand out DHCP leases; the
			# package just sits there, no service gets enabled.
			echo "!! hotspot needs dnsmasq once:  sudo pacman -S dnsmasq"
			echo "   (or use a phone hotspot and run:  splendor --no-hotspot)"
		else
			echo "!! hotspot failed — staying on the current network (--no-hotspot to silence this)"
		fi
	fi
elif [[ "$want_hotspot" == 1 ]]; then
	echo "!! no wifi interface found — staying on the current network"
fi

# ------------------------------------------------------------- firewall ----
# A live firewall looks exactly like a broken hotspot. Phones hang on
# "obtaining IP address" because DHCPDISCOVER arrives from 0.0.0.0 — no
# subnet rule can ever match it, the port itself has to be open — and the
# game page never loads because 8000/8001 are closed. ufw's rule file is
# world-readable, so checking costs nothing and needs no sudo.
firewall_preflight() {
	command -v ufw >/dev/null 2>&1 || return 0
	systemctl is-active --quiet ufw 2>/dev/null || return 0
	local rules=/etc/ufw/user.rules
	[[ -r "$rules" ]] || return 0

	local -a need=()
	if [[ "$hotspot_up" == 1 ]]; then
		grep -qE -- "--dport 67" "$rules" \
			|| need+=("ufw allow in on ${wifi_if} to any port 67 proto udp comment 'splendor dhcp'")
		grep -qE -- "-s 10\.42\.0\.0/24" "$rules" \
			|| need+=("ufw allow from 10.42.0.0/24 comment 'splendor hotspot'")
	else
		grep -qE -- "--dport ${http}\b|--dport ${http}:${ws}\b" "$rules" \
			|| need+=("ufw allow ${http}:${ws}/tcp comment 'splendor'")
	fi
	((${#need[@]})) || return 0

	echo
	echo "  !! ufw is active and will block friends. Needed:"
	printf '       sudo %s\n' "${need[@]}"
	echo
	local ans=""
	read -r -p "  run these now? [Y/n] " ans || true
	if [[ -z "$ans" || "$ans" =~ ^[Yy] ]]; then
		local c
		for c in "${need[@]}"; do
			eval "sudo $c" || echo "  !! failed: sudo $c"
		done
	else
		echo "  ok — skipping. Friends will not get in until those rules exist."
	fi
}
firewall_preflight

ips() {
	# "iface ip" per useful interface — LAN and tailscale reach friends,
	# docker/bridge ranges do not.
	ip -4 -o addr show scope global 2>/dev/null \
		| awk '$2 !~ /^(lo|docker|br-|veth|virbr)/ {print $2, $4}' \
		| cut -d/ -f1
}

echo
echo "  SPLENDOR MULTIPLAYER"
lan_ips=()
ts_ip=""
while read -r iface ipaddr; do
	[[ -z "$ipaddr" ]] && continue
	if [[ "$iface" == tailscale* || "$iface" == ts* ]]; then
		[[ -z "$ts_ip" ]] && ts_ip="$ipaddr"
	else
		lan_ips+=("$ipaddr")
	fi
done < <(ips)
lan_ip="${lan_ips[0]:-}"

if [[ "$hotspot_up" == 1 ]]; then
	echo
	echo "  1. friends scan to join your wifi:"
	echo
	if command -v qrencode >/dev/null 2>&1; then
		qrencode -t ANSIUTF8 -m 2 "WIFI:T:WPA;S:${ssid};P:${pass};;"
	fi
	echo "      network: $ssid    password: $pass"
	echo "      (phones warn \"no internet\" — expected, tell them to stay connected)"
	echo
	echo "  2. then open the game:"
else
	echo
	echo "  friends on the same network open:"
fi
echo
if [[ -z "$lan_ip" ]]; then
	echo "      (no LAN address found — is the hotspot up?)"
else
	for ipaddr in "${lan_ips[@]}"; do
		echo "      http://$ipaddr:$http"
	done
	echo
	if command -v qrencode >/dev/null 2>&1; then
		qrencode -t ANSIUTF8 -m 2 "http://$lan_ip:$http"
		echo "      ^ or scan this"
	fi
fi
echo
echo "  you: the game window opens itself -> RACE FRIENDS -> JOIN (pre-filled)"
if [[ "$hotspot_up" != 1 && -n "$ts_ip" ]]; then
	echo
	echo "  network blocks device-to-device traffic (eduroam)?"
	echo "  friends on your tailnet use instead: http://$ts_ip:$http"
fi
echo
echo "  options:  splendor --no-hotspot   stay on current wifi"
echo "            splendor --no-game      lobby only, no game window"
echo "            splendor 8000 --dist=10000   10 km race"
echo "  ctrl-c shuts everything down (lobby, game, hotspot)"
echo

# --------------------------------------------------------------- serve ----

godot --headless --path . --script res://tools/mp_server.gd -- \
	--http="$http" --ws="$ws" --webroot="$web" "$@" &
server_pid=$!
sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
	echo "!! lobby failed to start — is port $http in use?" >&2
	exit 1
fi

# Host's own game window — native build, joins the lobby via the pre-filled
# ws://127.0.0.1:<ws> address in RACE FRIENDS.
if [[ "$want_game" == 1 && -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
	godot --path . >/dev/null 2>&1 &
	game_pid=$!
fi

wait "$server_pid" || true
