package main

import (
	"fmt"
	"strings"
)

// hasGPUData reports whether the collector found a real GPU (not the
// "No GPU metrics available" placeholder).
func hasGPUData(gpus []GPUStatus) bool {
	return len(gpus) > 0 && (gpus[0].MemoryTotal > 0 || gpus[0].Usage > 0 || gpus[0].Note == "")
}

// renderGPUCard replaces the Power card on machines without a battery.
func renderGPUCard(gpus []GPUStatus, thermal ThermalStatus) cardData {
	g := gpus[0]
	lines := []string{subtleStyle.Render(g.Name)}

	usageText := fmt.Sprintf("%5.1f%%", g.Usage)
	if thermal.GPUTemp > 0 {
		usageText += fmt.Sprintf(" @ %s°C", colorizeTemp(thermal.GPUTemp))
	}
	lines = append(lines, fmt.Sprintf("Usage  %s  %s", progressBar(g.Usage), usageText))

	if g.MemoryTotal > 0 {
		pct := g.MemoryUsed / g.MemoryTotal * 100
		lines = append(lines, fmt.Sprintf("VRAM   %s  %5.1f%% %s/%s", progressBar(pct), pct,
			humanBytesShort(uint64(g.MemoryUsed*(1<<20))), humanBytesShort(uint64(g.MemoryTotal*(1<<20)))))
	}

	var extras []string
	if thermal.FanSpeed > 0 {
		extras = append(extras, fmt.Sprintf("Fan %d RPM", thermal.FanSpeed))
	}
	if len(gpus) > 1 {
		extras = append(extras, fmt.Sprintf("+%d more GPU", len(gpus)-1))
	}
	if g.Note != "" {
		extras = append(extras, g.Note)
	}
	if len(extras) > 0 {
		lines = append(lines, subtleStyle.Render(strings.Join(extras, " · ")))
	}
	return cardData{icon: iconGPU, title: "GPU", lines: lines}
}

// isPrimaryLinuxInterface matches physical Ethernet/Wi-Fi names (enp34s0,
// eth0, wlan0, wlp3s0) and skips bridges, VPNs and container links.
func isPrimaryLinuxInterface(name string) bool {
	for _, prefix := range []string{"en", "eth", "wl"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

// linuxDiskLabel names a disk row after its mount point: "/" is ROOT, others
// use the last path element, clipped to the six-character label column.
func linuxDiskLabel(mount string) string {
	switch mount {
	case "/":
		return "ROOT"
	case "/home":
		return "HOME"
	}
	name := mount[strings.LastIndex(mount, "/")+1:]
	if name == "" {
		return "DISK"
	}
	if len([]rune(name)) > 6 {
		name = string([]rune(name)[:5]) + "…"
	}
	return name
}
