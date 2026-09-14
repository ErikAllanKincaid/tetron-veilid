#!/usr/bin/env bash
# Bringup logic for tetron-veilid. Sourced by bin/tetron-veilid -- never
# executed directly. Depends on lib/common.sh already being sourced
# (run_on, upload_to, VEILID_HOSTS, log_*, fatal).

set -uo pipefail

readonly VEILID_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TETRON_VEILID_GH_REPO="ErikAllanKincaid/tetron-veilid"

readonly TV_CONFIG_DIR="/etc/tetron-veilid"
readonly TV_STATE_DIR="/var/lib/tetron-veilid"
readonly TV_CONFIG_FILE="$TV_CONFIG_DIR/veilid-server.conf"
readonly TV_BIN_PATH="/usr/local/bin/tetron-veilid-server"
readonly TV_UNIT_PATH="/etc/systemd/system/tetron-veilid.service"

# tv_arch_asset <host>
# Maps `uname -m` on the target to the arch token this repo's own release
# assets use (see .github/workflows/release.yml's matrix `name` values).
tv_arch_asset() {
	local host="$1"
	local m
	m="$(run_on "$host" "uname -m")" || fatal "tv_arch_asset: could not run uname on '$host'"
	case "$m" in
	x86_64) echo "x86_64" ;;
	aarch64 | arm64) echo "aarch64" ;;
	*) fatal "tv_arch_asset: unsupported architecture '$m' on '$host' -- tetron-veilid only publishes x86_64/aarch64 linux-gnu builds" ;;
	esac
}

# tv_install_binary <host>
# Downloads and installs the latest tetron-veilid-server release tarball
# matching the target's arch, verifying its published sha256. Fetched
# directly on the target (needs outbound internet either way, to reach
# the real public Veilid network once running) rather than shipped
# through the controller.
tv_install_binary() {
	local host="$1"
	local arch
	arch="$(tv_arch_asset "$host")"

	log_info "resolving latest tetron-veilid release asset for linux-$arch"
	run_on "$host" "
		set -e
		api_url='https://api.github.com/repos/${TETRON_VEILID_GH_REPO}/releases/latest'
		release_json=\$(curl -fsSL \"\$api_url\")
		asset_url=\$(echo \"\$release_json\" | grep -o '\"browser_download_url\": *\"[^\"]*tetron-veilid-server-linux-${arch}-[^\"]*\\.tar\\.gz\"' | head -n1 | sed 's/.*\"\\(https[^\"]*\\)\"/\\1/')
		[ -n \"\$asset_url\" ] || { echo 'no matching release asset found for linux-${arch}' >&2; exit 1; }
		sha_url=\"\${asset_url}.sha256\"
		tmpdir=\$(mktemp -d)
		curl -fsSL \"\$asset_url\" -o \"\$tmpdir/asset.tar.gz\"
		curl -fsSL \"\$sha_url\" -o \"\$tmpdir/asset.tar.gz.sha256\" || echo 'warning: no .sha256 asset found, skipping checksum verification' >&2
		if [ -s \"\$tmpdir/asset.tar.gz.sha256\" ]; then
			( cd \"\$tmpdir\" && sed 's/tetron-veilid-server.*\\.tar\\.gz/asset.tar.gz/' asset.tar.gz.sha256 | sha256sum -c - ) \\
				|| { echo 'checksum verification failed' >&2; exit 1; }
		fi
		tar -xzf \"\$tmpdir/asset.tar.gz\" -C \"\$tmpdir\"
		[ -x \"\$tmpdir/tetron-veilid-server\" ] || { echo 'tetron-veilid-server binary not found in release tarball' >&2; exit 1; }
		sudo install -m 0755 \"\$tmpdir/tetron-veilid-server\" '$TV_BIN_PATH'
		rm -rf \"\$tmpdir\"
	" || fatal "tv_install_binary: failed on '$host'"

	run_on "$host" "test -x '$TV_BIN_PATH'" || fatal "tv_install_binary: '$TV_BIN_PATH' not found or not executable on '$host' after install"
}

# tv_create_user <host>
# Idempotent: a second `up` run against an already-provisioned host must
# not fail just because the user/dirs already exist.
tv_create_user() {
	local host="$1"
	run_on "$host" "sudo id tetron-veilid >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin tetron-veilid" \
		|| fatal "tv_create_user: could not create system user 'tetron-veilid' on '$host'"
	run_on "$host" "sudo install -d -o root -g tetron-veilid -m 0750 '$TV_CONFIG_DIR' && sudo install -d -o tetron-veilid -g tetron-veilid -m 0750 '$TV_STATE_DIR'" \
		|| fatal "tv_create_user: could not create $TV_CONFIG_DIR/$TV_STATE_DIR on '$host'"
}

# tv_render_config <listen_address>
# Renders templates/veilid-server.conf.tmpl to a local temp file, returns
# its path. Simple single-placeholder substitution -- no multi-line
# blocks like tetron-relay's config needs, so plain sed is sufficient
# here.
tv_render_config() {
	local listen_address="$1"
	local out
	out="$(mktemp)"
	sed "s|__LISTEN_ADDRESS__|$listen_address|g" "$VEILID_ROOT/templates/veilid-server.conf.tmpl" >"$out"
	echo "$out"
}

# tv_install_config <host> <listen_address>
tv_install_config() {
	local host="$1" listen_address="$2"
	local rendered
	rendered="$(tv_render_config "$listen_address")"
	upload_to "$host" "$rendered" "/tmp/tetron-veilid-server.conf"
	rm -f "$rendered"
	run_on "$host" "sudo install -o root -g tetron-veilid -m 0640 /tmp/tetron-veilid-server.conf '$TV_CONFIG_FILE' && rm -f /tmp/tetron-veilid-server.conf" \
		|| fatal "tv_install_config: could not install config on '$host'"
}

# tv_install_unit <host>
tv_install_unit() {
	local host="$1"
	upload_to "$host" "$VEILID_ROOT/templates/tetron-veilid.service.tmpl" "/tmp/tetron-veilid.service"
	run_on "$host" "sudo install -m 0644 /tmp/tetron-veilid.service '$TV_UNIT_PATH' && rm -f /tmp/tetron-veilid.service && sudo systemctl daemon-reload" \
		|| fatal "tv_install_unit: could not install systemd unit on '$host'"
}

# veilid_up <host> <listen_address>
veilid_up() {
	local host="$1" listen_address="$2"
	log_info "bringing up tetron-veilid on '$host' (listen: $listen_address)"
	tv_create_user "$host"
	tv_install_binary "$host"
	tv_install_config "$host" "$listen_address"
	tv_install_unit "$host"
	run_on "$host" "sudo systemctl enable --now tetron-veilid.service" \
		|| fatal "veilid_up: could not enable/start tetron-veilid.service on '$host'"
	log_info "tetron-veilid is up on '$host' -- check with: tetron-veilid status --host $host"
}

# veilid_status <host>
veilid_status() {
	local host="$1"
	run_on "$host" "sudo systemctl status --no-pager tetron-veilid.service" \
		|| fatal "veilid_status: could not query systemd status on '$host'"
}

# veilid_down <host> <purge>
veilid_down() {
	local host="$1" purge="$2"
	run_on "$host" "sudo systemctl disable --now tetron-veilid.service 2>/dev/null || true"
	if [[ "$purge" == "true" ]]; then
		log_warn "purging tetron-veilid from '$host' (binary, config, state, systemd unit, system user)"
		run_on "$host" "
			sudo rm -f '$TV_UNIT_PATH'
			sudo systemctl daemon-reload
			sudo rm -f '$TV_BIN_PATH'
			sudo rm -rf '$TV_CONFIG_DIR' '$TV_STATE_DIR'
			sudo userdel tetron-veilid 2>/dev/null || true
		" || fatal "veilid_down: purge failed on '$host'"
	fi
	log_info "tetron-veilid stopped on '$host'$([ "$purge" == "true" ] && echo ', purged')"
}
