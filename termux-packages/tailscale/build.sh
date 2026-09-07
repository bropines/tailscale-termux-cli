TERMUX_PKG_HOMEPAGE=https://tailscale.com
TERMUX_PKG_DESCRIPTION="Mesh VPN that makes it easy to connect your devices, wherever they are"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_LICENSE_FILE="LICENSE"
TERMUX_PKG_MAINTAINER="@bropines"
TERMUX_PKG_VERSION="1.100.0"
TERMUX_PKG_SRCURL=https://github.com/tailscale/tailscale/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=d9e097d82f08c8557c887ca71962b20f08e27f3b305902ea504bd0e472486b97
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_DEPENDS="termux-services"
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

	# Interface discovery on Android 11+ cannot use netlink; wlynxg/anet reads
	# the interface list through ioctl instead. See the netmon patch.
	go get github.com/wlynxg/anet@v0.0.5
	go mod tidy

	# Subsystems that cannot work, or make no sense, on a phone.
	local _TAGS="ts_no_clipboard,ts_omit_taildrop,ts_omit_systray,ts_omit_kube"
	_TAGS+=",ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions"
	_TAGS+=",ts_omit_networkmanager,ts_omit_sdnotify,ts_omit_ssh"

	# -checklinkname=0 is required by wlynxg/anet on Go 1.23 and later:
	# https://github.com/wlynxg/anet?tab=readme-ov-file#how-to-build-with-go-1230-or-later
	local _LDFLAGS="-s -w -checklinkname=0"

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
