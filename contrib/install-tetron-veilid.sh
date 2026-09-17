#!/usr/bin/env bash
# install-tetron-veilid.sh: install/upgrade/uninstall the tetron-veilid
# companion daemon on THIS machine -- no clone, no hosts.conf, no SSH
# controller. Fetch this file directly (raw.githubusercontent.com) and
# run it.
#
# This is the standalone counterpart to bin/tetron-veilid (this repo's
# SSH-controller tool for managing a *fleet* of hosts via hosts.conf).
# Both end up doing the same install steps (see lib/veilid.sh's
# veilid_up/veilid_down) -- this script exists for the common case of
# "just set this up on the machine I'm already on", including from
# tetron-webui's addon-install framework, which cannot itself run
# anything as root.
#
# Usage:
#   ./install-tetron-veilid.sh [--check] [--listen ADDR:PORT] [--binary-path FILE]
#   ./install-tetron-veilid.sh --uninstall [--purge]
#
#   --check          report installed vs. latest version only, change nothing
#   --listen ADDR    client_api listen address (default 127.0.0.1:5959,
#                    matching tetron's own veilid-transport default). The
#                    wire protocol carries no authentication of any kind --
#                    only widen this if you specifically intend a remote/
#                    shared instance and plan to restrict access with your
#                    own firewall rule; this script does not do that for you.
#   --binary-path FILE   install this local binary instead of fetching the
#                    latest GitHub release -- for the dev loop before a
#                    release exists, or a binary built for a different
#                    VEILID_PIN/platform than CI covers.
#   --uninstall      stop + disable the service. Add --purge to also remove
#                    the binary, config, state directory, systemd unit, and
#                    the dedicated system user.
#
# Needs sudo (system-wide install: /usr/local/bin, /etc/systemd/system, a
# dedicated system user) -- same privilege tier as tetron core itself.

set -uo pipefail

log_info()  { printf '[info]  %s\n' "$*" >&2; }
log_warn()  { printf '[warn]  %s\n' "$*" >&2; }
log_error() { printf '[error] %s\n' "$*" >&2; }
log_pass()  { printf '[pass]  %s\n' "$*" >&2; }

fatal() {
	log_error "$*"
	exit 1
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || fatal "required command not found: $cmd"
	done
}

require_cmd curl tar sudo

readonly TETRON_VEILID_GH_REPO="ErikAllanKincaid/tetron-veilid"
readonly TV_CONFIG_DIR="/etc/tetron-veilid"
readonly TV_STATE_DIR="/var/lib/tetron-veilid"
readonly TV_CONFIG_FILE="$TV_CONFIG_DIR/veilid-server.conf"
readonly TV_BIN_PATH="/usr/local/bin/tetron-veilid-server"
readonly TV_UNIT_PATH="/etc/systemd/system/tetron-veilid.service"

CHECK_ONLY=0
UNINSTALL=0
PURGE=0
LISTEN_ADDRESS="127.0.0.1:5959"
BINARY_PATH=""

while [ $# -gt 0 ]; do
	case "$1" in
	--check) CHECK_ONLY=1; shift ;;
	--uninstall) UNINSTALL=1; shift ;;
	--purge) PURGE=1; shift ;;
	--listen) LISTEN_ADDRESS="$2"; shift 2 ;;
	--binary-path) BINARY_PATH="$2"; shift 2 ;;
	-h | --help)
		sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) fatal "unrecognized argument: $1 (see --help)" ;;
	esac
done

[ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -ne 1 ] && fatal "--purge only makes sense with --uninstall"

if [ "$UNINSTALL" -eq 1 ]; then
	sudo systemctl disable --now tetron-veilid.service 2>/dev/null || true
	if [ "$PURGE" -eq 1 ]; then
		log_warn "purging tetron-veilid (binary, config, state, systemd unit, system user)"
		sudo rm -f "$TV_UNIT_PATH"
		sudo systemctl daemon-reload
		sudo rm -f "$TV_BIN_PATH"
		sudo rm -rf "$TV_CONFIG_DIR" "$TV_STATE_DIR"
		sudo userdel tetron-veilid 2>/dev/null || true
		log_pass "tetron-veilid purged"
	else
		log_pass "tetron-veilid stopped (binary/config/state left in place -- rerun with --purge for a full removal)"
	fi
	exit 0
fi

os="$(uname -s)"
[ "$os" = "Linux" ] || fatal "tetron-veilid only publishes Linux builds (got: $os)"
arch="$(uname -m)"
case "$arch" in
x86_64) plat_arch=x86_64 ;;
aarch64 | arm64) plat_arch=aarch64 ;;
*) fatal "unsupported architecture: $arch -- tetron-veilid only publishes x86_64/aarch64 linux-gnu builds" ;;
esac

installed_version() {
	[ -x "$TV_BIN_PATH" ] || return 0
	# veilid-server has no tetron-specific --version wrapper -- its own
	# --version prints upstream veilid's version, not a tetron-veilid
	# release tag, so there is nothing reliable to compare against a
	# GitHub release tag here. Presence is the only signal `--check` has.
	echo "present"
}

if [ "$CHECK_ONLY" -eq 1 ]; then
	if [ -n "$(installed_version)" ]; then
		if systemctl is-active --quiet tetron-veilid.service 2>/dev/null; then
			log_pass "tetron-veilid: installed, service active"
		else
			log_warn "tetron-veilid: binary present, service NOT active"
		fi
	else
		log_info "tetron-veilid: not installed"
	fi
	exit 0
fi

log_info "creating system user/dirs..."
sudo id tetron-veilid >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin tetron-veilid \
	|| fatal "could not create system user 'tetron-veilid'"
sudo install -d -o root -g tetron-veilid -m 0750 "$TV_CONFIG_DIR" \
	&& sudo install -d -o tetron-veilid -g tetron-veilid -m 0750 "$TV_STATE_DIR" \
	|| fatal "could not create $TV_CONFIG_DIR/$TV_STATE_DIR"

if [ -n "$BINARY_PATH" ]; then
	[ -f "$BINARY_PATH" ] || fatal "local binary not found: $BINARY_PATH"
	log_info "installing local binary '$BINARY_PATH' (skipping GitHub release fetch)"
	sudo install -m 0755 "$BINARY_PATH" "$TV_BIN_PATH" || fatal "failed to install local binary"
else
	log_info "resolving latest tetron-veilid release asset for linux-$plat_arch..."
	api_url="https://api.github.com/repos/${TETRON_VEILID_GH_REPO}/releases/latest"
	release_json="$(curl -fsSL "$api_url")" || fatal "failed to query $api_url"
	asset_url="$(printf '%s' "$release_json" | grep -o "\"browser_download_url\": *\"[^\"]*tetron-veilid-server-linux-${plat_arch}-[^\"]*\\.tar\\.gz\"" | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/')"
	[ -n "$asset_url" ] || fatal "no matching release asset found for linux-$plat_arch"
	sha_url="${asset_url}.sha256"
	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT
	log_info "downloading $asset_url ..."
	curl -fsSL "$asset_url" -o "$tmpdir/asset.tar.gz" || fatal "failed to download release asset"
	if curl -fsSL "$sha_url" -o "$tmpdir/asset.tar.gz.sha256" 2>/dev/null && [ -s "$tmpdir/asset.tar.gz.sha256" ]; then
		( cd "$tmpdir" && sed 's/tetron-veilid-server.*\.tar\.gz/asset.tar.gz/' asset.tar.gz.sha256 | sha256sum -c - ) \
			|| fatal "checksum verification failed"
	else
		log_warn "no .sha256 asset found -- skipping checksum verification"
	fi
	tar -xzf "$tmpdir/asset.tar.gz" -C "$tmpdir"
	[ -x "$tmpdir/tetron-veilid-server" ] || fatal "tetron-veilid-server binary not found in release tarball"
	sudo install -m 0755 "$tmpdir/tetron-veilid-server" "$TV_BIN_PATH" || fatal "failed to install binary"
fi
[ -x "$TV_BIN_PATH" ] || fatal "$TV_BIN_PATH not found or not executable after install"

log_info "writing config (listen: $LISTEN_ADDRESS)..."
tmp_conf="$(mktemp)"
cat >"$tmp_conf" <<EOF
logging:
  system:
    enabled: true
    level: info
  terminal:
    enabled: false
core:
  network:
    protocol:
      udp:
        listen_address: ':5150'
      tcp:
        listen_address: ':5150'
      ws:
        listen_address: ':5150'
      wss:
        listen_address: ':5150'
  protected_store:
    directory: '$TV_STATE_DIR/protected_store'
  table_store:
    directory: '$TV_STATE_DIR/table_store'
  block_store:
    directory: '$TV_STATE_DIR/block_store'
client_api:
  ipc_enabled: false
  network_enabled: true
  listen_address: '$LISTEN_ADDRESS'
EOF
sudo install -o root -g tetron-veilid -m 0640 "$tmp_conf" "$TV_CONFIG_FILE" || fatal "could not install config"
rm -f "$tmp_conf"

log_info "installing systemd unit..."
tmp_unit="$(mktemp)"
cat >"$tmp_unit" <<EOF
[Unit]
Description=tetron-veilid (footgun-nodeid-target build of veilid-server, for tetron's external-daemon Veilid transport)
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=RUST_BACKTRACE=1
ExecStart=$TV_BIN_PATH --config-file $TV_CONFIG_FILE
ExecReload=/bin/kill -s HUP \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=5
WorkingDirectory=/
User=tetron-veilid
Group=tetron-veilid
UMask=0002

CapabilityBoundingSet=
SystemCallFilter=@system-service
MemoryDenyWriteExecute=true
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
PrivateUsers=true
ProtectHome=true
ProtectClock=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ReadWritePaths=$TV_STATE_DIR
ConfigurationDirectory=tetron-veilid
ConfigurationDirectoryMode=0750
StateDirectory=tetron-veilid

RestrictRealtime=true
SystemCallArchitectures=native
LockPersonality=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "$tmp_unit" "$TV_UNIT_PATH" || fatal "could not install systemd unit"
rm -f "$tmp_unit"
sudo systemctl daemon-reload

log_info "enabling + starting tetron-veilid.service..."
sudo systemctl enable --now tetron-veilid.service || fatal "could not enable/start tetron-veilid.service"

log_pass "tetron-veilid is up -- check with: sudo systemctl status tetron-veilid"
