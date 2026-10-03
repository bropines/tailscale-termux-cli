TERMUX_PKG_HOMEPAGE=https://tailscale.com
TERMUX_PKG_DESCRIPTION="Mesh VPN that makes it easy to connect your devices, wherever they are"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_LICENSE_FILE="LICENSE"
TERMUX_PKG_MAINTAINER="@bropines"
TERMUX_PKG_VERSION="1.104.0"
TERMUX_PKG_SRCURL=https://github.com/tailscale/tailscale/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=d5ef52c6561de4a9ab671964976e205859250627817f65a9c1f9245b409efa95
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_BUILD_IN_SRC=true
# Tailscale 1.104.0 resolves through Android's own resolver daemon
# (feature/androiddns), so resolv-conf is no longer what makes DNS work. It is
# still the fallback the Go toolchain uses if that daemon's socket does not
# answer, and it costs nothing, so keep it.
TERMUX_PKG_DEPENDS="termux-services, resolv-conf"
# The out-of-tree build at github.com/bropines/tailscale-termux-cli installs
# the same two binaries.
TERMUX_PKG_CONFLICTS="tailscale-termux"
TERMUX_PKG_REPLACES="tailscale-termux"

termux_step_make() {
	termux_setup_golang

	local _goarch _goarm=""
	case "$TERMUX_ARCH" in
		aarch64) _goarch=arm64 ;;
		arm)     _goarch=arm; _goarm=7 ;;
		i686)    _goarch=386 ;;
		x86_64)  _goarch=amd64 ;;
		*) termux_error_exit "Unsupported architecture: $TERMUX_ARCH" ;;
	esac

	# GOOS=android is what makes the //go:build android patches apply, and it
	# needs external (cgo) linking on every architecture except arm64 -- so
	# CGO_ENABLED must be 1, using the NDK compiler $CC that the Termux
	# toolchain has already exported for $TERMUX_ARCH.
	export GOOS=android
	export GOARCH="$_goarch"
	export CGO_ENABLED=1
	if [ -n "$_goarm" ]; then
		export GOARM="$_goarm"
	else
		unset GOARM
	fi

	# Nothing is added to go.mod: interface discovery comes from the Go
	# toolchain Termux ships, which carries the netlink and resolv.conf
	# patches, and name resolution from Tailscale's own feature/androiddns.
	# Earlier revisions of this recipe pulled in github.com/wlynxg/anet for
	# the first of those; it is not needed and neither is the
	# -checklinkname=0 it required.

	# Subsystems that cannot work, or make no sense, on a phone.
	local _TAGS="ts_no_clipboard,ts_omit_taildrop,ts_omit_systray,ts_omit_kube"
	_TAGS+=",ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions"
	_TAGS+=",ts_omit_networkmanager,ts_omit_sdnotify,ts_omit_ssh"

	local _LDFLAGS="-s -w"

	go build -trimpath -tags "$_TAGS" -ldflags "$_LDFLAGS" -buildmode=pie -o tailscaled ./cmd/tailscaled
	go build -trimpath -tags "$_TAGS" -ldflags "$_LDFLAGS" -buildmode=pie -o tailscale ./cmd/tailscale
}

termux_step_make_install() {
	install -Dm700 -t "$TERMUX_PREFIX"/bin tailscale tailscaled

	install -d "$TERMUX_PREFIX/etc/tailscale"
	install -m600 "$TERMUX_PKG_BUILDER_DIR/tailscaled.conf" \
		"$TERMUX_PREFIX/etc/tailscale/tailscaled.conf"

	./tailscale completion bash > "$TERMUX_PREFIX/share/bash-completion/completions/tailscale" || true
	./tailscale completion zsh > "$TERMUX_PREFIX/share/zsh/site-functions/_tailscale" || true
	./tailscale completion fish > "$TERMUX_PREFIX/share/fish/vendor_completions.d/tailscale.fish" || true
}

termux_step_post_make_install() {
	mkdir -p "$TERMUX_PREFIX/var/service/tailscaled/log"
	ln -sf "$TERMUX_PREFIX/share/termux-services/svlogger" "$TERMUX_PREFIX/var/service/tailscaled/log/run"
	sed "s%@TERMUX_PREFIX@%$TERMUX_PREFIX%g" "$TERMUX_PKG_BUILDER_DIR/sv/tailscaled.run.in" \
		> "$TERMUX_PREFIX/var/service/tailscaled/run"
	chmod 700 "$TERMUX_PREFIX/var/service/tailscaled/run"
	# Do not start the daemon just because the package was installed.
	touch "$TERMUX_PREFIX/var/service/tailscaled/down"
}

termux_step_create_debscripts() {
	cat <<- EOF > ./prerm
		#!${TERMUX_PREFIX}/bin/sh
		cd ${TERMUX_PREFIX}
		if [ -x "${TERMUX_PREFIX}/bin/sv" ]; then
			sv-disable tailscaled || :
			sv down tailscaled || :
		fi
		rm -rf ${TERMUX_PREFIX}/var/service/tailscaled
	EOF
	chmod 0700 prerm
}
