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

web_stale=0
if [[ ! -f "$web/index.html" || ! -f "$web/index.pck" ]]; then
	web_stale=1
elif find scripts scenes shaders assets addons project.godot export_presets.cfg \
	-type f -newer "$web/index.pck" -print -quit 2>/dev/null | grep -q .; then
	web_stale=1
fi
if [[ "$web_stale" == 1 ]]; then
	echo ">> web build is missing or stale — exporting the current game…"
	if ! godot --headless --path . --export-release "Web" "$web/index.html"; then
		echo "!! export failed. Install the matching Godot 4.7.2 export templates and re-run." >&2
		exit 1
	fi
fi

# Fail before changing networks. Discovering a stale process only after the
# laptop has dropped its internet connection makes a simple port conflict look
# like a broken hotspot and leaves friends with a QR code that cannot answer.
for port in "$http" "$ws"; do
	if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
		echo "!! port $port is already in use. Stop the old Splendor host and retry." >&2
		exit 1
	fi
done

# ------------------------------------------------------------- hotspot ----

ssid="splendor"
pass="splendor"
hotspot_up=0
made_hotspot=0
port80_hop=0
hotip=""
server_pid=""
game_pid=""

captive_conf=/etc/NetworkManager/dnsmasq-shared.d/splendor.conf

wifi_ip() {
	ip -4 -o addr show dev "$wifi_if" scope global 2>/dev/null \
		| awk '{print $4}' | cut -d/ -f1 | head -1
}

write_captive_conf() {
	# Wildcard every DNS answer at the hotspot gateway so phones' "is there
	# internet?" probes reach mp_server, which answers them — an unanswered
	# probe is what makes Android badge the wifi "no internet" and silently
	# route the game link over mobile data. NM's dnsmasq reads
	# dnsmasq-shared.d only when a shared connection starts, so this must be
	# on disk BEFORE `nmcli dev wifi hotspot` runs. Removed on exit — left
	# behind, it would hijack DNS on any other hotspot you start later.
	[[ -d /etc/NetworkManager/dnsmasq-shared.d ]] || return 1
	printf 'address=/dns.msftncsi.com/131.107.255.255\naddress=/#/%s\n' "$1" \
		| sudo tee "$captive_conf" >/dev/null
}

port80_on() {
	sudo iptables -t nat -C PREROUTING -i "$wifi_if" -p tcp --dport 80 \
		-m comment --comment splendor -j REDIRECT --to-ports "$http" 2>/dev/null \
		|| sudo iptables -t nat -A PREROUTING -i "$wifi_if" -p tcp --dport 80 \
		-m comment --comment splendor -j REDIRECT --to-ports "$http" 2>/dev/null
}

port80_off() {
	sudo -n iptables -t nat -D PREROUTING -i "$wifi_if" -p tcp --dport 80 \
		-m comment --comment splendor -j REDIRECT --to-ports "$http" 2>/dev/null || true
}

cleanup() {
	[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
	[[ -n "$game_pid" ]] && kill "$game_pid" 2>/dev/null || true
	[[ "$port80_hop" == 1 ]] && port80_off
	if [[ -f "$captive_conf" ]]; then
		sudo -n rm -f "$captive_conf" 2>/dev/null \
			|| echo "!! leftover $captive_conf — delete it or it wildcards DNS on future hotspots"
	fi
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
		hotip=$(wifi_ip)
		echo ">> hotspot '$ssid' already up — reusing it"
		# dnsmasq already spawned — a conf written now lands next run.
		write_captive_conf "${hotip:-10.42.0.1}" || true
	elif nmcli -t -f NAME con show --active 2>/dev/null | grep -qx "Hotspot"; then
		hotspot_up=1
		hotip=$(wifi_ip)
		echo ">> a hotspot ('$active_ssid') is already running — using it"
		write_captive_conf "${hotip:-10.42.0.1}" || true
	else
		# The wildcard must be on disk before dnsmasq spawns at bring-up.
		# NM always shares 10.42.0.1 unless configured otherwise — verified below.
		write_captive_conf 10.42.0.1 || true
		echo ">> starting hotspot '$ssid' (this laptop drops off the internet — the game is all local)"
		if nmcli dev wifi hotspot ifname "$wifi_if" ssid "$ssid" password "$pass" >/dev/null 2>&1; then
			made_hotspot=1
			hotspot_up=1
			for _ in {1..10}; do
				ip -4 addr show dev "$wifi_if" | grep -q 'inet ' && break
				sleep 0.5
			done
			hotip=$(wifi_ip)
			if [[ -n "$hotip" && "$hotip" != "10.42.0.1" ]]; then
				write_captive_conf "$hotip" || true
				echo ">> hotspot ip is $hotip (not 10.42.0.1) — captive spoof applies from next run"
			fi
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
	# The game ports must be open no matter which network friends arrive
	# from — the hotspot-subnet rule alone doesn't cover phone-hotspot or LAN
	# joins, and a closed port looks exactly like a dead server.
	grep -qE -- "--dport ${http}\b" "$rules" \
		|| need+=("ufw allow ${http}:${ws}/tcp comment 'splendor'")
	if [[ "$hotspot_up" == 1 ]]; then
		# DHCPDISCOVER arrives from 0.0.0.0 — no subnet rule can ever match it,
		# the port itself has to be open or phones hang on "obtaining IP".
		grep -qE -- "--dport 67" "$rules" \
			|| need+=("ufw allow in on ${wifi_if} to any port 67 proto udp comment 'splendor dhcp'")
		# Hotspot clients get a full pass too — derived from the live address,
		# not a hardcoded subnet.
		local subnet=""
		if [[ "$hotip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
			subnet="${BASH_REMATCH[1]}.0/24"
			grep -qF -- "-s $subnet" "$rules" \
				|| need+=("ufw allow from $subnet comment 'splendor hotspot'")
		fi
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

# --------------------------------------------------------- port 80 hop ----
# Phones' captive-portal probes and bare-IP visits all arrive on :80 — bounce
# them to the game port. With the DNS wildcard above, any address a phone
# tries resolves to the gateway and lands on the game, no typing needed.
if [[ "$hotspot_up" == 1 ]]; then
	if port80_on; then
		port80_hop=1
	else
		echo ">> skipped :80 redirect (needs sudo) — friends must include :$http in the link"
	fi
fi

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
	echo "      (phones may still warn \"no internet\" — tell them to keep the wifi anyway)"
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
	if [[ "$port80_hop" == 1 && -n "$hotip" ]]; then
		echo "      http://$hotip    (no port — DNS is wildcarded, any address lands here)"
	fi
	echo
	if command -v qrencode >/dev/null 2>&1; then
		qrencode -t ANSIUTF8 -m 2 "http://$lan_ip:$http"
		echo "      ^ or scan this"
	fi
fi
echo
echo "  you: the game window opens itself -> RACE FRIENDS -> JOIN (pre-filled)"
echo "  if a friend's page still spins: their phone is bypassing the hotspot —"
echo "  mobile data OFF, VPN off, then reopen the link."
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
if curl -fsSo /dev/null --max-time 5 "http://127.0.0.1:$http/"; then
	echo ">> serving — every friend request logs below as 'http <ip> <path>'"
else
	echo "!! server is up but not answering — check the webroot: $web" >&2
fi

# Host's own game window — native build, joins the lobby via the pre-filled
# ws://127.0.0.1:<ws> address in RACE FRIENDS.
if [[ "$want_game" == 1 && -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
	godot --path . >/dev/null 2>&1 &
	game_pid=$!
fi

wait "$server_pid" || true
