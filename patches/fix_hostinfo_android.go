// SPDX-License-Identifier: BSD-3-Clause
//
// Termux patch for cmd/tailscaled. See LICENSE at the repository root.

//go:build android || linux

package main

import (
	"fmt"

	"tailscale.com/hostinfo"
	"tailscale.com/tailcfg"
)

// This file is what remains of the old fix_android_netmon.go.
//
// The interface-discovery and DNS workarounds it used to carry are gone: the
// Go toolchain is now patched with Termux's own standard-library fixes (see
// patches/go/), so net.Interfaces() and name resolution work on Android
// without this project intervening. That replaced ~470 lines of ifconfig
// parsing, /proc/net/if_inet6 reading and UDPv6 probing with something that
// also reports cellular interfaces and global IPv6, which the old code
// struggled to see.
//
// Only the identity hook is still ours, and only because it is a deliberate
// behavioural choice rather than a workaround.
func init() {
	// Report as a CLI client rather than an Android app. Tailnet policies
	// that key on client type treat the Android app as a mobile device with
	// restrictions that do not apply here. Documented in the README, since it
	// is visible to tailnet administrators.
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		hi.App = "tailscale-cli"
		hi.DeviceModel = "Termux"
		if hi.Hostname == "" || hi.Hostname == "localhost" {
			hi.Hostname = "tailscale-termux"
		}
		fmt.Printf("[Termux] Reporting as App=%s DeviceModel=%s\n", hi.App, hi.DeviceModel)
	})
}
