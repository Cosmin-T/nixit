package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFixture(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func useSysfsFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	sysfsRoot = root
	t.Cleanup(func() { sysfsRoot = "/" })
	return root
}

func TestParseLspciDeviceName(t *testing.T) {
	out := `28:00.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Navi 44 [Radeon RX 9050 / 9060 XT]" -rc0 -p00 "Sapphire Technology Limited" "Device a493"`
	if got := parseLspciDeviceName(out); got != "Radeon RX 9050 / 9060 XT" {
		t.Fatalf("parseLspciDeviceName = %q", got)
	}
	if got := parseLspciDeviceName(`00:02.0 "VGA compatible controller" "Intel Corporation" "UHD Graphics 620"`); got != "UHD Graphics 620" {
		t.Fatalf("parseLspciDeviceName without brackets = %q", got)
	}
	if got := parseLspciDeviceName("garbage"); got != "" {
		t.Fatalf("parseLspciDeviceName(garbage) = %q", got)
	}
}

func TestLinuxMachineModelPrefersBoardName(t *testing.T) {
	root := useSysfsFixture(t)
	dmi := "sys/class/dmi/id/"
	writeFixture(t, root, dmi+"sys_vendor", "Micro-Star International Co., Ltd\n")
	writeFixture(t, root, dmi+"product_name", "MS-7B86\n")
	writeFixture(t, root, dmi+"board_vendor", "Micro-Star International Co., Ltd\n")
	writeFixture(t, root, dmi+"board_name", "B450 GAMING PLUS MAX (MS-7B86)\n")
	if got := linuxMachineModel(); got != "MSI B450 GAMING PLUS MAX (MS-7B86)" {
		t.Fatalf("linuxMachineModel = %q", got)
	}
}

func TestLinuxMachineModelLaptop(t *testing.T) {
	root := useSysfsFixture(t)
	dmi := "sys/class/dmi/id/"
	writeFixture(t, root, dmi+"sys_vendor", "LENOVO\n")
	writeFixture(t, root, dmi+"product_name", "ThinkPad T14 Gen 3\n")
	writeFixture(t, root, dmi+"board_name", "21AH00BXUS\n")
	if got := linuxMachineModel(); got != "Lenovo ThinkPad T14 Gen 3" {
		t.Fatalf("linuxMachineModel = %q", got)
	}
}

func TestLinuxCPUAndOSVersion(t *testing.T) {
	root := useSysfsFixture(t)
	writeFixture(t, root, "proc/cpuinfo", "processor\t: 0\nmodel name\t: AMD Ryzen 5 3600X 6-Core Processor\n")
	writeFixture(t, root, "etc/os-release", "NAME=\"CachyOS Linux\"\nPRETTY_NAME=\"CachyOS\"\n")
	if got := linuxCPUModel(); got != "AMD Ryzen 5 3600X 6-Core Processor" {
		t.Fatalf("linuxCPUModel = %q", got)
	}
	if got := linuxOSVersion(); got != "CachyOS" {
		t.Fatalf("linuxOSVersion = %q", got)
	}
}

func TestCollectThermalLinux(t *testing.T) {
	root := useSysfsFixture(t)
	writeFixture(t, root, "sys/class/hwmon/hwmon0/name", "nvme\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon0/temp1_input", "38850\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/name", "amdgpu\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/temp1_label", "edge\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/temp1_input", "44000\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/temp2_label", "junction\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/temp2_input", "51000\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon1/fan1_input", "754\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon2/name", "k10temp\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon2/temp1_label", "Tctl\n")
	writeFixture(t, root, "sys/class/hwmon/hwmon2/temp1_input", "54750\n")

	thermal := collectThermalLinux()
	if thermal.CPUTemp != 54.75 || thermal.GPUTemp != 44 {
		t.Fatalf("temps = cpu %v gpu %v", thermal.CPUTemp, thermal.GPUTemp)
	}
	if thermal.FanCount != 1 || thermal.FanSpeed != 754 {
		t.Fatalf("fans = %d @ %d", thermal.FanCount, thermal.FanSpeed)
	}
}

func TestReadLinuxDRMGPUs(t *testing.T) {
	root := useSysfsFixture(t)
	dev := "sys/class/drm/card1/device/"
	writeFixture(t, root, dev+"uevent", "DRIVER=amdgpu\nPCI_SLOT_NAME=\n")
	writeFixture(t, root, dev+"gpu_busy_percent", "37\n")
	writeFixture(t, root, dev+"mem_info_vram_used", "1073741824\n")
	writeFixture(t, root, dev+"mem_info_vram_total", "17179869184\n")
	writeFixture(t, root, "sys/class/drm/card1-DP-1/status", "connected\n")

	gpus := readLinuxDRMGPUs()
	if len(gpus) != 1 {
		t.Fatalf("expected 1 GPU, got %+v", gpus)
	}
	g := gpus[0]
	if g.Name != "AMD GPU" || g.Usage != 37 || g.MemoryUsed != 1024 || g.MemoryTotal != 16384 {
		t.Fatalf("unexpected GPU: %+v", g)
	}
}

func TestLinuxMemoryPressure(t *testing.T) {
	root := useSysfsFixture(t)
	cases := []struct {
		psi  string
		want string
	}{
		{"some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n", "normal"},
		{"some avg10=12.50 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.20 avg60=0.00 avg300=0.00 total=0\n", "warn"},
		{"some avg10=55.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=20.00 avg60=0.00 avg300=0.00 total=0\n", "critical"},
	}
	for _, c := range cases {
		writeFixture(t, root, "proc/pressure/memory", c.psi)
		if got := linuxMemoryPressure(); got != c.want {
			t.Errorf("linuxMemoryPressure(%q) = %q, want %q", c.psi, got, c.want)
		}
	}
}

func TestLinuxDiskLabel(t *testing.T) {
	cases := map[string]string{"/": "ROOT", "/home": "HOME", "/mnt/DownloadsSSD": "Downl…", "/data": "data"}
	for mount, want := range cases {
		if got := linuxDiskLabel(mount); got != want {
			t.Errorf("linuxDiskLabel(%q) = %q, want %q", mount, got, want)
		}
	}
}

func TestIsPrimaryLinuxInterface(t *testing.T) {
	for _, name := range []string{"enp34s0", "eth0", "wlan0", "wlp3s0"} {
		if !isPrimaryLinuxInterface(name) {
			t.Errorf("%s should be primary", name)
		}
	}
	for _, name := range []string{"virbr0", "docker0", "tailscale0", "lo", "veth12"} {
		if isPrimaryLinuxInterface(name) {
			t.Errorf("%s should not be primary", name)
		}
	}
}

func TestRenderGPUCard(t *testing.T) {
	card := renderGPUCard([]GPUStatus{{Name: "AMD Radeon RX 9060 XT", Usage: 12, MemoryUsed: 1024, MemoryTotal: 16384}}, ThermalStatus{GPUTemp: 40, FanSpeed: 700})
	if card.title != "GPU" || len(card.lines) != 4 {
		t.Fatalf("unexpected GPU card: %+v", card)
	}
	if !hasGPUData([]GPUStatus{{Name: "x", MemoryTotal: 1}}) || hasGPUData([]GPUStatus{{Name: "No GPU metrics available", Note: "Install nvidia-smi"}}) {
		t.Fatal("hasGPUData misclassified")
	}
}
