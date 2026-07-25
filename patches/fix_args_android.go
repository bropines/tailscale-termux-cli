//go:build android || linux

package main

import (
	"os"
	"path/filepath"
	"strings"
)

func init() {
	// Workaround for Termux duplicate argv[0]/argv[1] bug.
	// In some Termux environment configurations, os.Args[1] is populated with the executable path.
	if len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "-") {
		arg := os.Args[1]
		if arg == os.Args[0] || filepath.Base(arg) == filepath.Base(os.Args[0]) || strings.HasSuffix(arg, "/tailscaled") || strings.HasSuffix(arg, "/tailscale") {
			// Remove the duplicated executable path from os.Args
			os.Args = append(os.Args[:1], os.Args[2:]...)
		}
	}

	// For tailscale CLI on Android: default --socket to ~/.tailscale/tailscaled.sock if not specified
	prog := filepath.Base(os.Args[0])
	if prog == "tailscale" || prog == "tailscale-cli" {
		hasSocket := false
		for _, arg := range os.Args[1:] {
			if strings.HasPrefix(arg, "--socket=") || arg == "--socket" {
				hasSocket = true
				break
			}
		}
		if !hasSocket {
			home := os.Getenv("HOME")
			if home != "" {
				defaultSock := filepath.Join(home, ".tailscale", "tailscaled.sock")
				newArgs := make([]string, 0, len(os.Args)+1)
				newArgs = append(newArgs, os.Args[0], "--socket="+defaultSock)
				newArgs = append(newArgs, os.Args[1:]...)
				os.Args = newArgs
			}
		}
	}
}

