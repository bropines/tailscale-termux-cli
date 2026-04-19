//go:build android

package main

import (
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"tailscale.com/hostinfo"
	"tailscale.com/net/netmon"
	"tailscale.com/tailcfg"
)

func init() {
	// 1. Mask as CLI to bypass mobile-specific policies
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		hi.App = "tailscale-cli"
		hi.DeviceModel = "Termux"
		if hi.Hostname == "" || hi.Hostname == "localhost" {
			hi.Hostname = "tailscale-termux"
		}
		fmt.Printf("[Termux] Masking App as: %s, DeviceModel: %s\n", hi.App, hi.DeviceModel)

		// Set DNS fallback early
		if os.Getenv("TS_DEBUG_NAMESERVERS") == "" {
			os.Setenv("TS_DEBUG_NAMESERVERS", "8.8.8.8,1.1.1.1")
			fmt.Printf("[Termux] No DNS detected, using fallback: 8.8.8.8, 1.1.1.1\n")
		}
	})

	// 2. Register custom interface getter using ifconfig
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		out, err := exec.Command("ifconfig").Output()
		if err != nil {
			fmt.Printf("[Termux] ifconfig exec error: %v\n", err)
			return []netmon.Interface{}, nil
		}

		var ifs []netmon.Interface
		var current *netmon.Interface
		var curNetIf *net.Interface

		lines := strings.Split(string(out), "\n")
		idx := 1
		for _, line := range lines {
			if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "Warning:") {
				continue
			}

			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
				if current != nil {
					ifs = append(ifs, *current)
				}
				parts := strings.SplitN(line, ":", 2)
				if len(parts) != 2 {
					current = nil
					continue
				}
				name := strings.TrimSpace(parts[0])

				mtu := 0
				if mtuIdx := strings.Index(line, "mtu "); mtuIdx != -1 {
					mtuFields := strings.Fields(line[mtuIdx+4:])
					if len(mtuFields) > 0 {
						mtu, _ = strconv.Atoi(mtuFields[0])
					}
				}

				var flags net.Flags
				if strings.Contains(line, "<UP") || strings.Contains(line, ",UP") { flags |= net.FlagUp }
				if strings.Contains(line, "LOOPBACK") { flags |= net.FlagLoopback }
				if strings.Contains(line, "BROADCAST") { flags |= net.FlagBroadcast }
				if strings.Contains(line, "MULTICAST") { flags |= net.FlagMulticast }
				if strings.Contains(line, "POINTOPOINT") { flags |= net.FlagPointToPoint }

				curNetIf = &net.Interface{Index: idx, Name: name, MTU: mtu, Flags: flags}
				idx++
				current = &netmon.Interface{Interface: curNetIf}
			} else if current != nil {
				trimmed := strings.TrimSpace(line)
				if strings.HasPrefix(trimmed, "inet ") {
					fields := strings.Fields(trimmed)
					if len(fields) >= 4 && fields[2] == "netmask" {
						ip := net.ParseIP(fields[1])
						maskIP := net.ParseIP(fields[3])
						if ip != nil && maskIP != nil {
							mask := net.IPMask(maskIP.To4())
							if mask == nil { mask = net.IPMask(maskIP.To16()) }
							current.AltAddrs = append(current.AltAddrs, &net.IPNet{IP: ip, Mask: mask})
						}
					}
				} else if strings.HasPrefix(trimmed, "inet6 ") {
					fields := strings.Fields(trimmed)
					if len(fields) >= 3 && fields[2] == "prefixlen" {
						ip := net.ParseIP(fields[1])
						prefixLen, _ := strconv.Atoi(fields[3])
						if ip != nil {
							mask := net.CIDRMask(prefixLen, 128)
							current.AltAddrs = append(current.AltAddrs, &net.IPNet{IP: ip, Mask: mask})
						}
					}
				}
			}
		}
		if current != nil { ifs = append(ifs, *current) }
		return ifs, nil
	})
}

// Global variable to ensure we can patch DNS even deeper if needed
var termuxNameservers = []netip.Addr{
	netip.MustParseAddr("8.8.8.8"),
	netip.MustParseAddr("1.1.1.1"),
}
