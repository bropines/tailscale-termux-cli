// SPDX-License-Identifier: BSD-3-Clause
//
// Termux patch for cmd/tailscaled. See LICENSE at the repository root.

//go:build android || linux

package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/wlynxg/anet"
	"tailscale.com/hostinfo"
	"tailscale.com/net/netmon"
	"tailscale.com/tailcfg"
)

// parseProcNetIfInet6 parses /proc/net/if_inet6 for IPv6 addresses.
// Works on some Android devices but may be blocked by SELinux.
func parseProcNetIfInet6() (map[string][]*net.IPNet, error) {
	f, err := os.Open("/proc/net/if_inet6")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	result := map[string][]*net.IPNet{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		hexAddr := fields[0]
		prefixLen, _ := strconv.Atoi(fields[2])
		ifName := fields[5]

		if prefixLen <= 0 || prefixLen > 128 {
			prefixLen = 64
		}

		ip := net.IP(make([]byte, 16))
		for i := 0; i < 16; i++ {
			val, err := strconv.ParseUint(hexAddr[i*2:i*2+2], 16, 8)
			if err != nil {
				return nil, fmt.Errorf("parse /proc/net/if_inet6 hex: %w", err)
			}
			ip[i] = byte(val)
		}

		// Skip ULA (fd00::/8 — Tailscale IPs) and link-local (fe80::/10)
		if len(ip) > 0 && ip[0] == 0xfd {
			continue
		}
		if ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
			continue
		}
		if ip.IsLoopback() {
			continue
		}

		mask := net.CIDRMask(prefixLen, 128)
		result[ifName] = append(result[ifName], &net.IPNet{IP: ip, Mask: mask})
	}
	return result, scanner.Err()
}

// detectIPv6Addr tries to discover the device's global IPv6 address
// by making an outbound UDPv6 connection and reading the source address.
// This works entirely in userspace and doesn't require /proc/net access.
func detectIPv6Addr() net.IP {
	// Try multiple well-known IPv6 addresses in case one is unreachable
	targets := []string{
		"[2001:4860:4860::8888]:53", // Google DNS
		"[2001:4860:4860::8844]:53", // Google DNS secondary
		"[2606:4700:4700::1111]:53", // Cloudflare DNS
		"[2620:fe::fe]:53",          // Quad9 DNS
	}
	for _, target := range targets {
		conn, err := net.DialTimeout("udp6", target, 3*time.Second)
		if err != nil {
			continue
		}
		defer conn.Close()

		localAddr := conn.LocalAddr().(*net.UDPAddr)
		if localAddr.IP != nil &&
			!localAddr.IP.IsLinkLocalUnicast() &&
			!localAddr.IP.IsLoopback() &&
			!localAddr.IP.IsPrivate() &&
			localAddr.IP.To16() != nil &&
			localAddr.IP.To4() == nil {
			return localAddr.IP
		}
	}
	return nil
}

// termuxFallbackDNS is used only when the device will not tell us its own
// resolver. Public resolvers are blocked on some networks and by some
// carriers, which is why it is a last resort rather than the default.
const termuxFallbackDNS = "8.8.8.8:53"

// tailscaleCGNAT is the range Tailscale hands out to nodes (100.64.0.0/10,
// which contains the 100.100.100.100 MagicDNS resolver). Android sets
// net.dns1 to it while a Tailscale VPN profile is up; pointing the daemon's
// own lookups back at Tailscale would be circular, so such a value is
// rejected.
var tailscaleCGNAT = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// androidPropDNS reads a resolver address from an Android system property and
// returns it as host:port, or "" if it cannot be used.
//
// Everything about this is best-effort: it runs from init(), so it must never
// block for long and never panic. "" is returned when getprop is absent or
// fails, when the property is empty (net.dns1 is empty on many modern Android
// versions), when the value is not an IP address at all, and when the address
// is one we must not dial. getprop output is never passed on unvalidated.
func androidPropDNS(prop string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "getprop", prop).Output()
	if err != nil {
		return ""
	}
	ip := net.ParseIP(strings.TrimSpace(string(out)))
	if ip == nil || ip.IsLoopback() || ip.IsUnspecified() {
		return ""
	}
	if ip4 := ip.To4(); ip4 != nil && tailscaleCGNAT.Contains(ip4) {
		return ""
	}
	return net.JoinHostPort(ip.String(), "53")
}

// termuxDNSServer returns the resolver address tailscaled should dial, plus a
// short description of where that answer came from for the startup log. An
// empty address means keep Go's default resolver.
//
// Controlled by TS_DNS_SERVER: "system"/"default"/"off" means no override,
// any other value is used verbatim (a bare IP gets :53 appended). Unset asks
// Android for the resolver it is already using and falls back to
// termuxFallbackDNS only if that yields nothing usable.
func termuxDNSServer() (addr, source string) {
	v := strings.TrimSpace(os.Getenv("TS_DNS_SERVER"))
	switch strings.ToLower(v) {
	case "":
		// Prefer the device's own resolver: it follows the network the
		// phone is actually on, and it keeps working where a carrier or
		// network blocks public resolvers -- a failure that otherwise
		// shows up only as `tailscale up` hanging forever.
		for _, prop := range []string{"net.dns1", "net.dns2"} {
			if sysDNS := androidPropDNS(prop); sysDNS != "" {
				return sysDNS, "system resolver, " + prop
			}
		}
		return termuxFallbackDNS, "fallback, no system resolver reported"
	case "system", "default", "off":
		return "", "TS_DNS_SERVER=" + v
	}
	if _, _, err := net.SplitHostPort(v); err != nil {
		return net.JoinHostPort(v, "53"), "TS_DNS_SERVER"
	}
	return v, "TS_DNS_SERVER"
}

func init() {
	// 1. Mask as CLI to bypass mobile-specific policies
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		hi.App = "tailscale-cli"
		hi.DeviceModel = "Termux"
		if hi.Hostname == "" || hi.Hostname == "localhost" {
			hi.Hostname = "tailscale-termux"
		}
		fmt.Printf("[Termux] Masking App as: %s, DeviceModel: %s\n", hi.App, hi.DeviceModel)
	})

	// 2. Install a resolver.
	//
	// The binaries are built with CGO_ENABLED=0, so Go uses its pure-Go
	// resolver, which reads /etc/resolv.conf — a file Termux does not have.
	// Without this the daemon cannot resolve the control plane at all.
	//
	// With TS_DNS_SERVER unset this is the device's own resolver, and only
	// 8.8.8.8:53 if Android would not name one. Configurable via
	// TS_DNS_SERVER in ~/.tailscale/.env; "system" keeps Go's default
	// resolver. See README for the trade-offs.
	if dns, dnsSource := termuxDNSServer(); dns != "" {
		net.DefaultResolver = &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				var d net.Dialer
				// Honour the caller's transport: Go retries over TCP when a
				// UDP answer comes back truncated, and forcing that retry
				// onto UDP would lose the very answers it exists to fetch.
				if strings.HasPrefix(network, "tcp") {
					return d.DialContext(ctx, "tcp", dns)
				}
				return d.DialContext(ctx, "udp", dns)
			},
		}
		fmt.Printf("[Termux] DNS resolver pinned to %s (%s)\n", dns, dnsSource)
	} else {
		fmt.Printf("[Termux] DNS resolver: system default (%s)\n", dnsSource)
	}

	// 3. Register custom interface getter:
	//    - Interface list: anet.Interfaces() (ioctl-based, works on Android 11+)
	//    - IPv4 addresses: ifconfig per-interface
	//    - IPv6 addresses: /proc/net/if_inet6 (best) OR outbound UDPv6 probe (fallback)
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		// Try /proc/net/if_inet6 first
		ipv6Map, _ := parseProcNetIfInet6()
		if ipv6Map != nil {
			fmt.Printf("[Termux] /proc/net/if_inet6: %d ifs with global IPv6\n", len(ipv6Map))
			for name, addrs := range ipv6Map {
				for _, a := range addrs {
					fmt.Printf("[Termux]   %s: %s/%d\n", name, a.IP, maskOnes(a.Mask))
				}
			}
		} else {
			fmt.Printf("[Termux] /proc/net/if_inet6 unavailable\n")
		}

		// If /proc/net/if_inet6 found no global IPv6, try UDPv6 probe
		var udpDetectedIP net.IP
		if ipv6Map == nil || !hasGlobalV6InMap(ipv6Map) {
			udpDetectedIP = detectIPv6Addr()
			if udpDetectedIP != nil {
				fmt.Printf("[Termux] UDPv6 probe detected global IPv6: %s\n", udpDetectedIP)
			} else {
				fmt.Printf("[Termux] No IPv6 detected\n")
			}
		}

		// Get interfaces via anet
		anetIfs, err := anet.Interfaces()
		if err != nil {
			fmt.Printf("[Termux] anet.Interfaces error: %v, falling back to ifconfig\n", err)
			return ifconfigFallbackWithV6(ipv6Map, udpDetectedIP)
		}

		var ifs []netmon.Interface
		idx := 1
		for _, anetIf := range anetIfs {
			ni := &net.Interface{
				Index: idx,
				Name:  anetIf.Name,
				MTU:   anetIf.MTU,
				Flags: anetIf.Flags,
			}
			idx++

			nmIf := netmon.Interface{Interface: ni}

			// Get IPv4 from ifconfig
			nmIf.AltAddrs = getIPv4FromIfconfig(anetIf.Name)

			// Add IPv6 from /proc/net/if_inet6
			if ipv6Addrs, ok := ipv6Map[anetIf.Name]; ok {
				nmIf.AltAddrs = append(nmIf.AltAddrs, toNetAddrSlice(ipv6Addrs)...)
			}

			// If UDP probe detected IPv6 but no /proc/net/if_inet6 entry,
			// attach it to wlan0 (or the first non-loopback UP interface)
			if udpDetectedIP != nil && !hasIPv6(nmIf.AltAddrs) {
				if isUpAndNonLoopback(ni) {
					mask := net.CIDRMask(64, 128)
					nmIf.AltAddrs = append(nmIf.AltAddrs, &net.IPNet{IP: udpDetectedIP, Mask: mask})
					fmt.Printf("[Termux] Attached probed IPv6 %s to %s\n", udpDetectedIP, ni.Name)
					udpDetectedIP = nil // only attach once
				}
			}

			ifs = append(ifs, nmIf)
		}

		// If we still have a probed IPv6 but no suitable interface was found
		// (unlikely), add it anyway to the last UP interface
		if udpDetectedIP != nil && len(ifs) > 0 {
			for i := range ifs {
				if isUpAndNonLoopback(ifs[i].Interface) {
					mask := net.CIDRMask(64, 128)
					ifs[i].AltAddrs = append(ifs[i].AltAddrs, &net.IPNet{IP: udpDetectedIP, Mask: mask})
					fmt.Printf("[Termux] Late-attached probed IPv6 %s to %s\n", udpDetectedIP, ifs[i].Name)
					break
				}
			}
		}

		fmt.Printf("[Termux] interface discovery: %d ifs, v4=%t v6=%t\n",
			len(ifs), hasV4(ifs), hasV6(ifs))
		return ifs, nil
	})
}

func isUpAndNonLoopback(ifi *net.Interface) bool {
	if ifi == nil {
		return false
	}
	return (ifi.Flags&net.FlagUp != 0) && (ifi.Flags&net.FlagLoopback == 0)
}

func hasIPv6(addrs []net.Addr) bool {
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && isGlobalV6(ipnet.IP) {
			return true
		}
	}
	return false
}

func isGlobalV6(ip net.IP) bool {
	return ip.To4() == nil && ip.To16() != nil &&
		!ip.IsLinkLocalUnicast() &&
		!ip.IsLoopback() &&
		!ip.IsPrivate()
}

func hasGlobalV6InMap(m map[string][]*net.IPNet) bool {
	for _, addrs := range m {
		for _, a := range addrs {
			if isGlobalV6(a.IP) {
				return true
			}
		}
	}
	return false
}

func maskOnes(mask net.IPMask) int {
	ones, _ := mask.Size()
	return ones
}

func toNetAddrSlice(addrs []*net.IPNet) []net.Addr {
	result := make([]net.Addr, len(addrs))
	for i, a := range addrs {
		result[i] = a
	}
	return result
}

func hasV4(ifs []netmon.Interface) bool {
	for _, iface := range ifs {
		for _, addr := range iface.AltAddrs {
			if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				return true
			}
		}
	}
	return false
}

func hasV6(ifs []netmon.Interface) bool {
	for _, iface := range ifs {
		for _, addr := range iface.AltAddrs {
			if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() == nil && ipnet.IP.To16() != nil {
				return true
			}
		}
	}
	return false
}

// getIPv4FromIfconfig returns IPv4 addresses for a given interface
func getIPv4FromIfconfig(name string) []net.Addr {
	out, err := exec.Command("ifconfig", name).Output()
	if err != nil {
		return nil
	}

	var addrs []net.Addr
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "inet ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		ip := net.ParseIP(fields[1])
		if ip == nil {
			continue
		}
		var mask net.IPMask
		for i, f := range fields {
			if f == "netmask" && i+1 < len(fields) {
				if maskIP := net.ParseIP(fields[i+1]); maskIP != nil {
					if ip4 := maskIP.To4(); ip4 != nil {
						mask = net.IPMask(ip4)
					}
				}
			}
		}
		if mask == nil {
			mask = net.CIDRMask(24, 32)
		}
		addrs = append(addrs, &net.IPNet{IP: ip, Mask: mask})
	}
	return addrs
}

// ifconfigFallbackWithV6 uses ifconfig + IPv6 supplements
func ifconfigFallbackWithV6(ipv6Map map[string][]*net.IPNet, udpV6 net.IP) ([]netmon.Interface, error) {
	out, err := exec.Command("ifconfig").Output()
	if err != nil {
		fmt.Printf("[Termux] ifconfig exec error: %v\n", err)
		return []netmon.Interface{}, nil
	}

	var ifs []netmon.Interface
	var current *netmon.Interface

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
					fmt.Sscanf(mtuFields[0], "%d", &mtu)
				}
			}

			var flags net.Flags
			if strings.Contains(line, "<UP") || strings.Contains(line, ",UP") {
				flags |= net.FlagUp
			}
			if strings.Contains(line, "LOOPBACK") {
				flags |= net.FlagLoopback
			}
			if strings.Contains(line, "BROADCAST") {
				flags |= net.FlagBroadcast
			}
			if strings.Contains(line, "MULTICAST") {
				flags |= net.FlagMulticast
			}
			if strings.Contains(line, "POINTOPOINT") {
				flags |= net.FlagPointToPoint
			}

			current = &netmon.Interface{
				Interface: &net.Interface{
					Index: idx, Name: name, MTU: mtu, Flags: flags,
				},
			}
			idx++
		} else if current != nil {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "inet ") {
				fields := strings.Fields(trimmed)
				if len(fields) >= 4 && fields[2] == "netmask" {
					ip := net.ParseIP(fields[1])
					maskIP := net.ParseIP(fields[3])
					if ip != nil && maskIP != nil {
						mask := net.IPMask(maskIP.To4())
						if mask == nil {
							mask = net.IPMask(maskIP.To16())
						}
						current.AltAddrs = append(current.AltAddrs, &net.IPNet{IP: ip, Mask: mask})
					}
				}
			}
		}
	}
	if current != nil {
		ifs = append(ifs, *current)
	}

	// Add IPv6 from /proc/net/if_inet6
	for i := range ifs {
		if v6Addrs, ok := ipv6Map[ifs[i].Name]; ok {
			for _, v6 := range v6Addrs {
				ifs[i].AltAddrs = append(ifs[i].AltAddrs, v6)
			}
		}
	}

	// Add UDP-probed IPv6 to first suitable interface if not already present
	if udpV6 != nil {
		for i := range ifs {
			if isUpAndNonLoopback(ifs[i].Interface) && !hasIPv6(ifs[i].AltAddrs) {
				mask := net.CIDRMask(64, 128)
				ifs[i].AltAddrs = append(ifs[i].AltAddrs, &net.IPNet{IP: udpV6, Mask: mask})
				fmt.Printf("[Termux] ifconfigFallback: attached probed IPv6 %s to %s\n", udpV6, ifs[i].Name)
				break
			}
		}
	}

	fmt.Printf("[Termux] ifconfig fallback (with IPv6): %d ifs, v4=%t v6=%t\n",
		len(ifs), hasV4(ifs), hasV6(ifs))
	return ifs, nil
}
