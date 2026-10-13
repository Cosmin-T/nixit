package main

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Linux data sources for the cards that macOS fills from system_profiler,
// ioreg, powermetrics and friends. Everything here reads sysfs/procfs first and
// only shells out where the kernel has no equivalent (lspci for GPU names).

// sysfsRoot prefixes every sysfs/procfs path; tests point it at a fixture tree.
var sysfsRoot = "/"

func sysPath(parts ...string) string {
	return filepath.Join(append([]string{sysfsRoot}, parts...)...)
}

func readSysString(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func readSysInt(path string) (int64, bool) {
	value, err := strconv.ParseInt(readSysString(path), 10, 64)
	return value, err == nil
}

// collectHardwareStaticLinux fills the hardware card from DMI, cpuinfo and
// os-release.
func collectHardwareStaticLinux() HardwareInfo {
	return HardwareInfo{
		Model:     linuxMachineModel(),
		CPUModel:  linuxCPUModel(),
		OSVersion: linuxOSVersion(),
	}
}

func linuxMachineModel() string {
	dmi := func(name string) string {
		value := readSysString(sysPath("sys", "class", "dmi", "id", name))
		switch strings.ToLower(value) {
		case "", "default string", "to be filled by o.e.m.", "system product name", "system manufacturer", "none":
			return ""
		}
		return value
	}
	vendor, product := dmi("sys_vendor"), dmi("product_name")
	// Desktop boards often leave product_name as a bare model code; the board
	// name is the friendlier label (e.g. "B450 GAMING PLUS MAX").
	if board := dmi("board_name"); board != "" && (product == "" || strings.Contains(board, product)) {
		product = board
		if boardVendor := dmi("board_vendor"); boardVendor != "" {
			vendor = boardVendor
		}
	}
	vendor = shortVendorName(vendor)
	switch {
	case vendor != "" && product != "":
		return vendor + " " + product
	case product != "":
		return product
	case vendor != "":
		return vendor
	}
	return "Unknown"
}

func shortVendorName(vendor string) string {
	replacements := map[string]string{
		"Micro-Star International Co., Ltd":  "MSI",
		"Micro-Star International Co., Ltd.": "MSI",
		"ASUSTeK COMPUTER INC.":              "ASUS",
		"Gigabyte Technology Co., Ltd.":      "Gigabyte",
		"LENOVO":                             "Lenovo",
		"Dell Inc.":                          "Dell",
		"HP":                                 "HP",
		"Hewlett-Packard":                    "HP",
		"ASRock":                             "ASRock",
	}
	if short, ok := replacements[vendor]; ok {
		return short
	}
	return vendor
}

func linuxCPUModel() string {
	f, err := os.Open(sysPath("proc", "cpuinfo"))
	if err != nil {
		return "Unknown"
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), ":")
		if found && strings.TrimSpace(key) == "model name" {
			return strings.Join(strings.Fields(value), " ")
		}
	}
	return "Unknown"
}

func linuxOSVersion() string {
	for _, path := range []string{sysPath("etc", "os-release"), sysPath("usr", "lib", "os-release")} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		fields := map[string]string{}
		for line := range strings.Lines(string(data)) {
			key, value, found := strings.Cut(strings.TrimSpace(line), "=")
			if found {
				fields[key] = strings.Trim(value, `"'`)
			}
		}
		if name := fields["PRETTY_NAME"]; name != "" {
			return name
		}
		if name := fields["NAME"]; name != "" {
			return name
		}
	}
	return "Linux"
}

// readLinuxDRMGPUs reports AMD and Intel GPUs from the DRM sysfs interface.
// amdgpu exposes busy percent and VRAM; i915/xe only expose presence.
func readLinuxDRMGPUs() []GPUStatus {
	cards, _ := filepath.Glob(sysPath("sys", "class", "drm", "card[0-9]*"))
	sort.Strings(cards)
	var gpus []GPUStatus
	for _, card := range cards {
		if strings.Contains(filepath.Base(card), "-") {
			continue // connector, not a card
		}
		device := filepath.Join(card, "device")
		uevent := readSysString(filepath.Join(device, "uevent"))
		driver, slot := "", ""
		for line := range strings.Lines(uevent) {
			if v, ok := strings.CutPrefix(strings.TrimSpace(line), "DRIVER="); ok {
				driver = v
			}
			if v, ok := strings.CutPrefix(strings.TrimSpace(line), "PCI_SLOT_NAME="); ok {
				slot = v
			}
		}
		if driver == "" {
			continue
		}
		gpu := GPUStatus{Name: linuxGPUName(slot, driver)}
		if busy, ok := readSysInt(filepath.Join(device, "gpu_busy_percent")); ok {
			gpu.Usage = float64(busy)
		} else {
			gpu.Note = "Usage not exposed by " + driver
		}
		// VRAM in MiB, matching the nvidia-smi path.
		if used, ok := readSysInt(filepath.Join(device, "mem_info_vram_used")); ok {
			gpu.MemoryUsed = float64(used) / (1 << 20)
		}
		if total, ok := readSysInt(filepath.Join(device, "mem_info_vram_total")); ok {
			gpu.MemoryTotal = float64(total) / (1 << 20)
		}
		gpus = append(gpus, gpu)
	}
	return gpus
}

// linuxGPUName turns lspci's "Navi 44 [Radeon RX 9050 / 9060 XT]" into
// "AMD Radeon RX 9050 / 9060 XT".
func linuxGPUName(slot, driver string) string {
	vendor := map[string]string{"amdgpu": "AMD", "radeon": "AMD", "i915": "Intel", "xe": "Intel", "nouveau": "NVIDIA", "nvidia": "NVIDIA"}[driver]
	if slot != "" && commandExists("lspci") {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if out, err := runCmd(ctx, "lspci", "-mm", "-s", slot); err == nil {
			if name := parseLspciDeviceName(out); name != "" {
				if vendor != "" && !strings.HasPrefix(name, vendor) {
					return vendor + " " + name
				}
				return name
			}
		}
	}
	if vendor != "" {
		return vendor + " GPU"
	}
	return driver
}

func parseLspciDeviceName(out string) string {
	// Quoted fields: slot "class" "vendor" "device" ...
	var fields []string
	rest := out
	for {
		start := strings.IndexByte(rest, '"')
		if start < 0 {
			break
		}
		end := strings.IndexByte(rest[start+1:], '"')
		if end < 0 {
			break
		}
		fields = append(fields, rest[start+1:start+1+end])
		rest = rest[start+end+2:]
	}
	if len(fields) < 3 {
		return ""
	}
	device := fields[2]
	if open := strings.LastIndexByte(device, '['); open >= 0 {
		if close := strings.LastIndexByte(device, ']'); close > open {
			return strings.TrimSpace(device[open+1 : close])
		}
	}
	return device
}

// collectThermalLinux reads CPU/GPU temperatures and fans from hwmon.
func collectThermalLinux() ThermalStatus {
	var thermal ThermalStatus
	hwmons, _ := filepath.Glob(sysPath("sys", "class", "hwmon", "hwmon*"))
	sort.Strings(hwmons)
	for _, dir := range hwmons {
		name := readSysString(filepath.Join(dir, "name"))
		switch name {
		case "k10temp", "zenpower", "coretemp", "cpu_thermal":
			if thermal.CPUTemp == 0 {
				thermal.CPUTemp = hwmonTemp(dir, "Tctl", "Tdie", "Package id 0")
			}
		case "amdgpu", "nouveau", "i915", "xe":
			if thermal.GPUTemp == 0 {
				thermal.GPUTemp = hwmonTemp(dir, "edge")
			}
		case "acpitz":
			if thermal.CPUTemp == 0 {
				thermal.CPUTemp = hwmonTemp(dir)
			}
		}
		fans, _ := filepath.Glob(filepath.Join(dir, "fan[0-9]*_input"))
		for _, fan := range fans {
			if rpm, ok := readSysInt(fan); ok && rpm > 0 {
				thermal.FanCount++
				if int(rpm) > thermal.FanSpeed {
					thermal.FanSpeed = int(rpm)
				}
			}
		}
	}
	return thermal
}

// hwmonTemp returns the first temperature whose label matches one of the
// preferred labels, falling back to temp1. Values are in Celsius.
func hwmonTemp(dir string, preferredLabels ...string) float64 {
	labels, _ := filepath.Glob(filepath.Join(dir, "temp[0-9]*_label"))
	for _, want := range preferredLabels {
		for _, labelFile := range labels {
			if readSysString(labelFile) == want {
				input := strings.TrimSuffix(labelFile, "_label") + "_input"
				if milli, ok := readSysInt(input); ok {
					return float64(milli) / 1000
				}
			}
		}
	}
	if milli, ok := readSysInt(filepath.Join(dir, "temp1_input")); ok {
		return float64(milli) / 1000
	}
	return 0
}

// linuxMemoryPressure maps the kernel's PSI memory stall averages onto the
// normal/warn/critical scale macOS reports.
func linuxMemoryPressure() string {
	data := readSysString(sysPath("proc", "pressure", "memory"))
	if data == "" {
		return ""
	}
	var some, full float64
	for line := range strings.Lines(data) {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		value, ok := strings.CutPrefix(fields[1], "avg10=")
		if !ok {
			continue
		}
		parsed, err := strconv.ParseFloat(value, 64)
		if err != nil {
			continue
		}
		switch fields[0] {
		case "some":
			some = parsed
		case "full":
			full = parsed
		}
	}
	switch {
	case full >= 10 || some >= 40:
		return "critical"
	case full >= 1 || some >= 10:
		return "warn"
	}
	return "normal"
}

// linuxTrashPath is the freedesktop.org home Trash.
func linuxTrashPath(home string) string {
	if dataHome := os.Getenv("XDG_DATA_HOME"); filepath.IsAbs(dataHome) {
		return filepath.Join(dataHome, "Trash", "files")
	}
	return filepath.Join(home, ".local", "share", "Trash", "files")
}
