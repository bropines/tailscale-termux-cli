// SPDX-License-Identifier: BSD-3-Clause
//
// Termux patch: SOCKS5 credentials for tailscaled.
//
// Upstream's socks5.Server already supports Username/Password (see
// net/socks5/socks5.go), but cmd/tailscaled never populates them, so
// --socks5-server always listens unauthenticated. On Android the loopback
// interface is not isolated per-app: any installed app holding only the
// INTERNET permission can reach 127.0.0.1:<port> and get egress into the
// tailnet with this node's identity.
//
// build.sh injects Username/Password into the socks5.Server literal in
// cmd/tailscaled/proxy.go, calling the two helpers below. Credentials are
// read from the environment rather than from flags so they never appear in
// the process cmdline (visible to every process on the device via /proc).
//
// tailscaled-start generates and persists them; `tailscale-socks5` prints
// them back to the user.

//go:build !ts_omit_outboundproxy

package main

import "os"

// termuxSocks5User returns the SOCKS5 username the proxy requires, or "" to
// keep the proxy unauthenticated.
func termuxSocks5User() string {
	return os.Getenv("TS_SOCKS5_USER")
}

// termuxSocks5Pass returns the SOCKS5 password the proxy requires, or "" to
// keep the proxy unauthenticated.
func termuxSocks5Pass() string {
	return os.Getenv("TS_SOCKS5_PASS")
}
