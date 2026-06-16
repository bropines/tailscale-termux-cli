//go:build android

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
}
