//go:build windows

package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestBridgePermissionCancellationDoesNotStartHelper(t *testing.T) {
	old := bridgeElevate
	defer func() { bridgeElevate = old }()
	bridgeElevate = func(string) (int, error) { return errorCancelled, nil }
	p := validBridgePlan()
	s, e := startBridgeBroker(&p, "Start")
	if s != nil || e == nil || !strings.Contains(e.Error(), "cancelled") {
		t.Fatalf("%v %v", s, e)
	}
}
func TestBridgeBufferedCompletion(t *testing.T) {
	for i := 0; i < 100; i++ {
		s := &bridgeSession{states: make(chan bridgeMessage, 1), failed: make(chan error, 1), done: make(chan struct{})}
		s.states <- bridgeMessage{State: "complete"}
		close(s.done)
		if _, err := s.await("complete", time.Second); err != nil {
			t.Fatal(err)
		}
	}
}
func TestBridgeNativeOwnedFixture(t *testing.T) {
	exe := os.Getenv("BRIDGE_LAB_LAUNCHER")
	planPath := os.Getenv("BRIDGE_LAB_PLAN")
	qemu := os.Getenv("QEMU_SYSTEM")
	if exe == "" || planPath == "" || qemu == "" {
		t.Skip("requires explicitly owned disposable Windows lab fixture")
	}
	p, e := loadBridgePlan(planPath)
	if e != nil {
		t.Fatal(e)
	}
	old := bridgeElevate
	defer func() { bridgeElevate = old }()
	// The lab test already runs as SYSTEM. Execute the real candidate broker,
	// including protected extraction and IPC, without a second UI prompt.
	bridgeElevate = func(args string) (int, error) {
		cmd := exec.Command(exe, strings.Fields(args)...)
		if e := cmd.Run(); e != nil {
			return 1, e
		}
		return 0, nil
	}
	for cycle := 0; cycle < 2; cycle++ {
		t.Run(fmt.Sprint(cycle), func(t *testing.T) {
			s, e := startBridgeBroker(p, "Start")
			if e != nil {
				t.Fatal(e)
			}
			defer func() {
				if e := s.Close(); e != nil {
					t.Error(e)
				}
			}()
			if cycle == 0 {
				other, err := startBridgeBroker(p, "Start")
				if err == nil {
					other.Close()
					t.Fatal("duplicate broker accepted")
				}
				t.Log("duplicate setup refused while original owner remained active")
			}
			serial := filepath.Join(filepath.Dir(planPath), fmt.Sprintf("launcher-serial-%d.log", cycle))
			os.Remove(serial)
			root := filepath.Dir(planPath)
			args := []string{"-machine", "q35,accel=tcg", "-cpu", "qemu64", "-m", "384", "-nodefaults", "-no-user-config", "-display", "none", "-serial", "file:" + serial, "-kernel", filepath.Join(root, "bridge-fixture-kernel"), "-initrd", filepath.Join(root, "fixture-initrd-v20.gz"), "-append", "console=ttyS0 panic=1 net.ifnames=0 noapic", "-no-reboot"}
			var f forwardList
			f.Set("tcp:18092:8082")
			args = append(args, bridgeNetworkArgs(p, s.TapName, f)...)
			cmd := exec.Command(qemu, args...)
			log, e := os.Create(filepath.Join(root, fmt.Sprintf("launcher-qemu-%d.log", cycle)))
			if e != nil {
				t.Fatal(e)
			}
			defer log.Close()
			cmd.Stdout = log
			cmd.Stderr = log
			if e = cmd.Start(); e != nil {
				t.Fatal(e)
			}
			done := make(chan error, 1)
			go func() { e := cmd.Wait(); s.NoteQemuEnded(); done <- e }()
			defer func() {
				cmd.Process.Kill()
				select {
				case <-done:
				case <-time.After(10 * time.Second):
				}
			}()
			if e = s.Attach(cmd.Process.Pid, qemu); e != nil {
				t.Fatal(e)
			}
			deadline := time.Now().Add(100 * time.Second)
			var text string
			for time.Now().Before(deadline) {
				data, _ := os.ReadFile(serial)
				text = string(data)
				if strings.Contains(text, "FIXTURE_READY") {
					break
				}
				select {
				case e := <-s.failed:
					t.Fatal(e)
				case e := <-done:
					t.Fatalf("QEMU ended: %v", e)
				case <-time.After(time.Second):
				}
			}
			for _, marker := range []string{"FIXTURE_READY", "LAN_PEER: BridgeLabPeer", "PRIVATE_SERVICE: BridgePrivateService", "DNS_A_QUERY_PASSED"} {
				if !strings.Contains(text, marker) {
					t.Fatalf("missing %s in %s", marker, text)
				}
			}
			lease := regexp.MustCompile(`lease of (192\.0\.2\.[0-9]+) obtained`).FindStringSubmatch(text)
			if len(lease) != 2 {
				t.Fatal("LAN lease missing", text)
			}
			guestIP := lease[1]
			t.Log("guest LAN address:", guestIP)
			client := &http.Client{Timeout: 5 * time.Second}
			for _, url := range []string{"http://" + guestIP + ":8082/", "http://127.0.0.1:18092/"} {
				resp, e := client.Get(url)
				if e != nil {
					t.Fatal(e)
				}
				body, e := io.ReadAll(resp.Body)
				resp.Body.Close()
				if e != nil || strings.TrimSpace(string(body)) != guestIP {
					t.Fatalf("private/direct route: %s %v", body, e)
				}
			}
			t.Log("DHCP, DNS, direct host TCP, private services and loopback forwarding passed")
			if cycle == 0 {
				for _, size := range []int{1, 1048576, 2097152} {
					conn, err := net.DialTimeout("tcp4", net.JoinHostPort(guestIP, "8083"), 5*time.Second)
					if err != nil {
						t.Fatal(err)
					}
					conn.SetDeadline(time.Now().Add(20 * time.Second))
					data := make([]byte, size)
					for i := range data {
						data[i] = byte((i*31 + 17) % 251)
					}
					var packet bytes.Buffer
					binary.Write(&packet, binary.BigEndian, uint32(size))
					packet.Write(data)
					_, err = io.Copy(conn, &packet)
					if err != nil {
						conn.Close()
						t.Fatal(err)
					}
					reply := make([]byte, size)
					_, err = io.ReadFull(conn, reply)
					conn.Close()
					if err != nil || sha256.Sum256(data) != sha256.Sum256(reply) {
						t.Fatal("bulk TCP payload differs", size, err)
					}
					t.Log("direct host TCP exact payload passed", size)
				}
			}
			if cycle == 0 {
				if e = s.Close(); e != nil {
					t.Fatal(e)
				}
				if e = s.Close(); e != nil {
					t.Fatal("repeated cleanup", e)
				}
				t.Log("explicit stop and repeated cleanup passed")
			} else {
				cmd.Process.Kill()
				if _, e = s.await("complete", 40*time.Second); e != nil {
					t.Fatal("QEMU-exit recovery", e)
				}
				if e = s.Close(); e != nil {
					t.Fatal(e)
				}
				t.Log("QEMU-exit cleanup passed")
			}
		})
	}
	t.Run("wrong-pnp", func(t *testing.T) {
		changed := *p
		changed.TapPnp += "-replacement"
		session, e := startBridgeBroker(&changed, "Start")
		if e == nil {
			session.Close()
			t.Fatal("replacement PNP was accepted")
		}
		t.Log("replacement identity refused before preparation")
	})
	t.Run("parent-exit", func(t *testing.T) {
		self, e := os.Executable()
		if e != nil {
			t.Fatal(e)
		}
		child := exec.Command(self, "-test.run=^TestBridgeOrphanedBrokerChild$", "-test.v")
		child.Env = append(os.Environ(), "BRIDGE_LAB_ORPHAN_CHILD=1")
		output, e := child.CombinedOutput()
		if e != nil {
			t.Fatalf("orphan child: %v %s", e, output)
		}
		waitBridgeJournal(t, "Complete", 45*time.Second)
		s, e := startBridgeBroker(p, "Start")
		if e != nil {
			t.Fatal("orphan kept handles or lock", e)
		}
		if e = s.Close(); e != nil {
			t.Fatal(e)
		}
		t.Log("actual parent-process exit recovered TAP and released capture handles")
	})
	if os.Getenv("BRIDGE_LAB_ALLOW_LINK_FLAP") == "1" {
		t.Run("link-loss", func(t *testing.T) {
			s, e := startBridgeBroker(p, "Start")
			if e != nil {
				t.Fatal(e)
			}
			// Explicit owned VM-only switch. No production path changes Ethernet.
			flap := exec.Command(bridgeSystemDirectory()+`\WindowsPowerShell\v1.0\powershell.exe`, "-NoProfile", "-NonInteractive", "-Command", `$ErrorActionPreference='Stop';$p=Get-Content $env:BRIDGE_LAB_PLAN -Raw|ConvertFrom-Json;$vm=Get-CimInstance Win32_ComputerSystem;if($vm.Manufacturer -notmatch 'QEMU|Bochs'){throw 'Virtual QEMU lab required'};$a=Get-NetAdapter|Where-Object {([guid]$_.InterfaceGuid) -eq [guid]$p.wiredGuid};if($a.MacAddress -ne '52-54-00-16-60-01' -or $a.PnPDeviceID -ne $p.wiredPnp){throw 'Owned virtual Ethernet identity differs'};try{$a|Disable-NetAdapter -Confirm:$false;Start-Sleep 12}finally{Get-NetAdapter|Where-Object {([guid]$_.InterfaceGuid) -eq [guid]$p.wiredGuid}|Enable-NetAdapter -Confirm:$false}`)
			if e = flap.Start(); e != nil {
				t.Fatal(e)
			}
			select {
			case e = <-s.failed:
				t.Log("link loss stopped capture:", e)
			case <-time.After(35 * time.Second):
				t.Error("link loss did not stop capture")
			}
			_ = s.Close()
			if e = flap.Wait(); e != nil {
				t.Fatal(e)
			}
			waitBridgeJournal(t, "RecoveryRequired", 10*time.Second)
			recovered, e := startBridgeBroker(p, "Recover")
			if e != nil {
				t.Fatal(e)
			}
			if e = recovered.Close(); e != nil {
				t.Fatal(e)
			}
			waitBridgeJournal(t, "Complete", 5*time.Second)
			t.Log("link loss retained recovery; reconnect and explicit recovery passed")
		})
	}

}

func TestBridgeUnexpectedBrokerCompletion(t *testing.T) {
	for _, mode := range []string{"complete", "eof", "qemu-ended"} {
		t.Run(mode, func(t *testing.T) {
			old := bridgeElevate
			defer func() { bridgeElevate = old }()
			finish := make(chan struct{})
			bridgeElevate = func(args string) (int, error) {
				data, _ := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(args, "-bridge-broker "))
				var request bridgeBrokerRequest
				json.Unmarshal(data, &request)
				c, e := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", request.Port))
				if e != nil {
					return 1, e
				}
				defer c.Close()
				fmt.Fprintln(c, request.Token)
				r := bufio.NewReader(c)
				r.ReadString('\n')
				fmt.Fprintln(c, `{"state":"forwarding","tapName":"Owned TAP"}`)
				r.ReadString('\n')
				fmt.Fprintln(c, `{"state":"running"}`)
				<-finish
				if mode != "eof" {
					fmt.Fprintln(c, `{"state":"complete"}`)
				}
				return 0, nil
			}
			p := validBridgePlan()
			s, e := startBridgeBroker(&p, "Start")
			if e != nil {
				t.Fatal(e)
			}
			if e = s.Attach(123, `C:\owned\qemu-system-x86_64w.exe`); e != nil {
				t.Fatal(e)
			}
			if mode == "qemu-ended" {
				s.NoteQemuEnded()
			}
			close(finish)
			select {
			case <-s.done:
			case <-time.After(5 * time.Second):
				t.Fatal("completion stuck")
			}
			select {
			case e = <-s.failed:
				if mode == "qemu-ended" {
					t.Fatal("reported an expected QEMU exit", e)
				}
			default:
				if mode != "qemu-ended" {
					t.Fatal("unexpected exit did not stop VM ownership")
				}
			}
			if e = s.Close(); e != nil {
				t.Fatal(e)
			}
		})
	}
}

func waitBridgeJournal(t *testing.T, phase string, timeout time.Duration) {
	t.Helper()
	path := filepath.Join(os.Getenv("ProgramData"), "TryOmarchyLauncherBridge", "operation.json")
	deadline := time.Now().Add(timeout)
	var current struct {
		Phase string
		Error string
	}
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(path)
		json.Unmarshal(data, &current)
		if current.Phase == phase {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("journal phase %s, wanted %s: %s", current.Phase, phase, current.Error)
}
func TestBridgeOrphanedBrokerChild(t *testing.T) {
	if os.Getenv("BRIDGE_LAB_ORPHAN_CHILD") != "1" {
		t.Skip("owned subprocess only")
	}
	p, e := loadBridgePlan(os.Getenv("BRIDGE_LAB_PLAN"))
	if e != nil {
		t.Fatal(e)
	}
	bridgeElevate = func(args string) (int, error) {
		cmd := exec.Command(os.Getenv("BRIDGE_LAB_LAUNCHER"), strings.Fields(args)...)
		if e := cmd.Run(); e != nil {
			return 1, e
		}
		return 0, nil
	}
	if _, e = startBridgeBroker(p, "Start"); e != nil {
		t.Fatal(e)
	}
	os.Exit(0)
}
