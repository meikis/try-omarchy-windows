//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestNetworkSettingsNativeOptIn(t *testing.T) {
	launcher := os.Getenv("TRYOMARCHY_LAUNCHER_TEST_EXE")
	if os.Getenv("TRYOMARCHY_UI_TEST") != "1" || launcher == "" {
		t.Skip("requires isolated Windows UI candidate")
	}
	dir := t.TempDir()
	plan := validBridgePlan()
	prefs := networkPreferences{1, "nat", &plan}
	if err := saveNetworkPreferences(dir, prefs); err != nil {
		t.Fatal(err)
	}
	var spec buildSpec
	spec.Runtime.NetworkCapabilities = []string{dualNICCapability}
	data, _ := json.Marshal(spec)
	os.MkdirAll(filepath.Join(dir, "guest"), 0755)
	os.WriteFile(filepath.Join(dir, "guest", "build-spec.json"), data, 0600)
	cmd := exec.Command(launcher, "-dir", dir, "-settings")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	class, _ := syscall.UTF16PtrFromString("TryOmarchySettings")
	title, _ := syscall.UTF16PtrFromString(appTitle + " settings")
	var window, checkbox uintptr
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); {
		window, _, _ = user32.NewProc("FindWindowW").Call(uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(title)))
		if window != 0 {
			var owner uint32
			procGetWindowThreadProcessId.Call(window, uintptr(unsafe.Pointer(&owner)))
			if owner == uint32(cmd.Process.Pid) {
				checkbox, _, _ = user32.NewProc("GetDlgItem").Call(window, settingsBridgeOnID)
				if checkbox != 0 {
					break
				}
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	if checkbox == 0 {
		t.Fatal("bridge lab settings control missing")
	}
	checked, _, _ := procSendMessageW.Call(checkbox, bmGetcheck, 0, 0)
	if checked != 0 {
		t.Fatal("NAT default changed")
	}
	procSendMessageW.Call(checkbox, bmSetcheck, bstChecked, 0)
	procPostMessageW.Call(window, wmCommand, settingsSaveID, 0)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(15 * time.Second):
		dialogClass, _ := syscall.UTF16PtrFromString("#32770")
		caption, _ := syscall.UTF16PtrFromString(appTitle)
		dialog, _, _ := user32.NewProc("FindWindowW").Call(uintptr(unsafe.Pointer(dialogClass)), uintptr(unsafe.Pointer(caption)))
		var messages []string
		callback := syscall.NewCallback(func(handle, unused uintptr) uintptr {
			var text [2048]uint16
			procGetWindowTextW.Call(handle, uintptr(unsafe.Pointer(&text[0])), 2048)
			messages = append(messages, syscall.UTF16ToString(text[:]))
			return 1
		})
		user32.NewProc("EnumChildWindows").Call(dialog, callback, 0)
		t.Fatalf("bridge opt-in did not save: %v", messages)
	}
	got, err := loadNetworkPreferences(dir)
	if err != nil || got.Mode != "bridge-lab" || !reflect.DeepEqual(got.Bridge, &plan) {
		t.Fatalf("%+v %v", got, err)
	}
}
func TestNetworkRecoveryNativeCompleteAndCancellation(t *testing.T) {
	launcher := os.Getenv("BRIDGE_LAB_LAUNCHER")
	if launcher == "" {
		t.Skip("requires owned disposable Windows broker")
	}
	dir := t.TempDir()
	plan := validBridgePlan()
	prefs := networkPreferences{1, "bridge-lab", &plan}
	if err := saveNetworkPreferences(dir, prefs); err != nil {
		t.Fatal(err)
	}
	old := bridgeElevate
	defer func() { bridgeElevate = old }()
	bridgeElevate = func(string) (int, error) { return errorCancelled, nil }
	if runRecoveryUI(dir, "bridge-nat") == nil {
		t.Fatal("cancelled elevation succeeded")
	}
	got, err := loadNetworkPreferences(dir)
	if err != nil || !reflect.DeepEqual(got, prefs) {
		t.Fatal("cancellation changed saved mode", got, err)
	}
	// The elevated lab runs the real broker. Its completed journal may refer to
	// a removed TAP, so no driver or adapter mutation should be needed.
	bridgeElevate = func(args string) (int, error) {
		err := exec.Command(launcher, strings.Fields(args)...).Run()
		return 0, err
	}
	for i := 0; i < 2; i++ {
		if err := runRecoveryUI(dir, "bridge-nat"); err != nil {
			t.Fatal(err)
		}
		got, err = loadNetworkPreferences(dir)
		if err != nil || got.Mode != "nat" || !reflect.DeepEqual(got.Bridge, &plan) {
			t.Fatalf("%+v %v", got, err)
		}
	}
}

func TestNetworkFailureStopsBeforeNotice(t *testing.T) {
	old := bridgeFailureNotice
	defer func() { bridgeFailureNotice = old; guestNetworkFailed.Store(false) }()
	for _, pending := range []bool{false, true} {
		t.Run(fmt.Sprint(pending), func(t *testing.T) {
			proc := exec.Command(filepath.Join(bridgeSystemDirectory(), "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 60")
			proc.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
			if err := proc.Start(); err != nil {
				t.Fatal(err)
			}
			defer proc.Process.Kill()
			exited := make(chan error, 1)
			reaped := make(chan struct{})
			go func() { err := proc.Wait(); close(reaped); exited <- err }()
			cfg := &config{bridgeQemu: proc.Process}
			plan := validBridgePlan()
			cfg.bridge = &plan
			left, right := net.Pipe()
			defer right.Close()
			qmp := &qmpConn{tcp: left, lines: bufio.NewScanner(left), done: make(chan struct{})}
			defer qmp.close()
			guestNetworkFailed.Store(true)
			guestReady.Store(false)
			cleaned := false
			reported := false
			cleanup := func() error {
				select {
				case <-reaped:
				default:
					t.Error("cleanup raced the owned process")
				}
				cleaned = true
				if pending {
					return fmt.Errorf("owned adapter is missing")
				}
				return nil
			}
			bridgeFailureNotice = func(message string) {
				reported = true
				if !cleaned {
					t.Error("modal notice preceded cleanup")
				}
				if pending && !strings.Contains(message, "still pending") {
					t.Error("failed recovery reported success")
				}
				if !pending && !strings.Contains(message, "recovery completed") {
					t.Error("completed recovery not reported")
				}
			}
			if watch(cfg, qmp, exited, cleanup) {
				t.Fatal("failed bridge requested reboot")
			}
			if !cleaned || !reported {
				t.Fatal("failed network skipped cleanup or notice")
			}
		})
	}
}
