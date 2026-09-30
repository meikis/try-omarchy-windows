//go:build windows

package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	payload "github.com/omacom/try-omarchy-windows/networkpayload"
)

// All executable assets come from this binary. No elevated script or module is
// read from the plan, data directory, current directory, PATH or user temp.
const bridgeBootstrap = `
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TryOmarchyLauncherBridge'
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
function Assert-Trusted($path) {
 $item=Get-Item -LiteralPath $path
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Bridge paths must not be reparse points.'}
 $a=Get-Acl -LiteralPath $path
 if($a.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Untrusted bridge path owner.'}
 foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($r.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Untrusted bridge path permissions.'}}
}
if(-not (Test-Path -LiteralPath $root)){[IO.Directory]::CreateDirectory($root,$acl)|Out-Null}
Assert-Trusted $root
foreach($name in 'operation.json','operation.lock'){ $p=Join-Path $root $name;if(Test-Path -LiteralPath $p){Assert-Trusted $p} }
$operation=Join-Path $root ([guid]::NewGuid().ToString())
[IO.Directory]::CreateDirectory($operation,$acl)|Out-Null
try {
 $assets=[Console]::ReadLine() | ConvertFrom-Json
 foreach($entry in $assets.PSObject.Properties){
  if($entry.Name -notmatch '^[a-zA-Z0-9.-]+$'){throw 'Invalid embedded asset name.'}
  $file=Join-Path $operation $entry.Name
  $stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$data=[Convert]::FromBase64String($entry.Value);$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
 }
 $env:TEMP=$operation;$env:TMP=$operation
 $request=[Console]::ReadLine() | ConvertFrom-Json
 & (Join-Path $operation 'launcher-bridge.ps1') -Request $request -Directory $root
} catch {
 [Console]::WriteLine((@{state='error';error=$_.Exception.Message}|ConvertTo-Json -Compress));exit 1
} finally {Remove-Item -LiteralPath $operation -Recurse -Force}
`

var bridgeElevate = runElevated

type bridgeBrokerRequest struct {
	Port      int        `json:"port"`
	Token     string     `json:"token"`
	ParentPID int        `json:"parentPID"`
	Action    string     `json:"action"`
	Plan      bridgePlan `json:"plan"`
}
type bridgeMessage struct {
	State   string `json:"state"`
	TapName string `json:"tapName"`
	Error   string `json:"error"`
}
type bridgeSession struct {
	conn      net.Conn
	encoder   *json.Encoder
	states    chan bridgeMessage
	failed    chan error
	done      chan struct{}
	elevated  chan error
	once      sync.Once
	mu        sync.Mutex
	closeErr  error
	closing   atomic.Bool
	qemuEnded atomic.Bool
	TapName   string
}

func (s *bridgeSession) send(v any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return s.encoder.Encode(v)
}
func (s *bridgeSession) await(state string, timeout time.Duration) (bridgeMessage, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case m := <-s.states:
			if m.State == state {
				return m, nil
			}
			if m.State == "complete" {
				return m, fmt.Errorf("bridge ended before %s", state)
			}
		case e := <-s.failed:
			return bridgeMessage{}, e
		case <-s.done:
			// Completion can be buffered before the reader closes done.
			// Both are then ready, so do not lose a verified final state.
			select {
			case m := <-s.states:
				if m.State == state {
					return m, nil
				}
			default:
			}
			select {
			case e := <-s.failed:
				return bridgeMessage{}, e
			default:
			}
			return bridgeMessage{}, fmt.Errorf("bridge broker disconnected before %s", state)
		case <-setupCancelWake:
			return bridgeMessage{}, errSetupCancelled
		case <-timer.C:
			return bridgeMessage{}, fmt.Errorf("bridge broker timed out waiting for %s", state)
		}
	}
}
func (s *bridgeSession) Attach(pid int, executable string) error {
	if err := s.send(map[string]any{"action": "attach", "pid": pid, "executable": executable}); err != nil {
		return err
	}
	_, e := s.await("running", 30*time.Second)
	return e
}
func (s *bridgeSession) Close() error {
	if s == nil {
		return nil
	}
	s.once.Do(func() {
		s.closing.Store(true)
		_ = s.send(map[string]string{"action": "stop"})
		select {
		case <-s.done:
		case <-time.After(35 * time.Second):
			s.closeErr = fmt.Errorf("bridge cleanup is still pending; use the local recovery console")
		}
		s.conn.Close()
		select {
		case e := <-s.elevated:
			if e != nil {
				s.closeErr = e
			}
		case <-time.After(5 * time.Second):
			if s.closeErr == nil {
				s.closeErr = fmt.Errorf("bridge broker has not exited; recovery must finish before relaunch")
			}
		}
	})
	return s.closeErr
}
func startBridgeBroker(p *bridgePlan, action string) (*bridgeSession, error) {
	if os.Getenv("SSH_CONNECTION") != "" || os.Getenv("SSH_CLIENT") != "" || strings.HasPrefix(strings.ToUpper(os.Getenv("SESSIONNAME")), "RDP-") {
		return nil, fmt.Errorf("bridge requires an independent local recovery console")
	}

	if e := p.validate(); e != nil {
		return nil, e
	}
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return nil, e
	}
	defer listener.Close()
	token := make([]byte, 32)
	if _, e = rand.Read(token); e != nil {
		return nil, e
	}
	r := bridgeBrokerRequest{Port: listener.Addr().(*net.TCPAddr).Port, Token: hex.EncodeToString(token), ParentPID: os.Getpid(), Action: action, Plan: *p}
	data, _ := json.Marshal(r)
	encoded := base64.RawURLEncoding.EncodeToString(data)
	elevated := make(chan error, 1)
	go func() {
		code, e := bridgeElevate("-bridge-broker " + encoded)
		if e == nil && code != 0 {
			if code == errorCancelled {
				e = fmt.Errorf("bridge permission was cancelled; no VM was started")
			} else {
				e = fmt.Errorf("bridge broker exited with code %d", code)
			}
		}
		elevated <- e
	}()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, e := listener.Accept()
		if e == nil {
			accepted <- conn
		} else {
			accepted <- nil
		}
	}()
	var conn net.Conn
	select {
	case conn = <-accepted:
		if conn == nil {
			return nil, fmt.Errorf("bridge connection failed")
		}
	case e = <-elevated:
		listener.Close()
		if c := <-accepted; c != nil {
			c.Close()
		}
		if e == nil {
			e = fmt.Errorf("bridge broker ended before connecting")
		}
		return nil, e
	case <-time.After(150 * time.Second):
		listener.Close()
		if c := <-accepted; c != nil {
			c.Close()
		}
		return nil, fmt.Errorf("bridge permission timed out; no VM was started")
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(io.LimitReader(conn, 4<<20))
	line, e := reader.ReadString('\n')
	if e != nil || line != r.Token+"\n" {
		conn.Close()
		return nil, fmt.Errorf("bridge broker authentication failed")
	}
	conn.SetReadDeadline(time.Time{})
	if _, e = fmt.Fprintln(conn, "OK "+r.Token); e != nil {
		conn.Close()
		return nil, e
	}
	s := &bridgeSession{conn: conn, encoder: json.NewEncoder(conn), states: make(chan bridgeMessage, 8), failed: make(chan error, 1), done: make(chan struct{}), elevated: elevated}
	go func() {
		defer close(s.done)
		for {
			line, e := reader.ReadString('\n')
			if e != nil {
				if !s.closing.Load() && !s.qemuEnded.Load() {
					s.failed <- fmt.Errorf("bridge broker disconnected: %w", e)
				}
				return
			}
			var m bridgeMessage
			if len(line) > 65536 || json.Unmarshal([]byte(line), &m) != nil {
				s.failed <- fmt.Errorf("invalid bridge broker response")
				return
			}
			if m.State == "error" {
				s.failed <- fmt.Errorf("bridge: %s", m.Error)
				return
			}
			select {
			case s.states <- m:
			default:
				s.failed <- fmt.Errorf("unexpected bridge broker messages")
				return
			}
			if m.State == "complete" {
				if !s.closing.Load() && !s.qemuEnded.Load() && action != "Recover" {
					s.failed <- fmt.Errorf("bridge forwarding ended while its VM was still owned")
				}
				return
			}
		}
	}()
	if action == "Recover" {
		_, e = s.await("complete", 60*time.Second)
	} else {
		var m bridgeMessage
		m, e = s.await("forwarding", 60*time.Second)
		s.TapName = m.TapName
		if e == nil && (m.TapName == "" || len(m.TapName) > 256 || strings.ContainsAny(m.TapName, "\x00\r\n")) {
			e = fmt.Errorf("invalid TAP connection name")
		}
	}
	if e != nil {
		_ = s.Close()
		return nil, e
	}
	return s, nil
}
func runBridgeBroker(encoded string) error {
	if len(encoded) > 16000 {
		return fmt.Errorf("bridge request too large")
	}
	data, e := base64.RawURLEncoding.DecodeString(encoded)
	if e != nil {
		return e
	}
	var r bridgeBrokerRequest
	if e = json.Unmarshal(data, &r); e != nil {
		return e
	}
	if e = r.Plan.validate(); e != nil {
		return e
	}
	if r.Port < 1 || r.Port > 65535 || len(r.Token) != 64 || r.ParentPID < 1 || (r.Action != "Start" && r.Action != "Recover") {
		return fmt.Errorf("invalid bridge broker endpoint")
	}
	if _, e = hex.DecodeString(r.Token); e != nil {
		return e
	}
	conn, e := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(r.Port)), 5*time.Second)
	if e != nil {
		return e
	}
	defer conn.Close()
	pid, e := loopbackPeerPID(conn)
	if e != nil || int(pid) != r.ParentPID {
		return fmt.Errorf("bridge parent identity does not match")
	}
	fmt.Fprintln(conn, r.Token)
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(conn)
	ack, e := reader.ReadString('\n')
	if e != nil || ack != "OK "+r.Token+"\n" {
		return fmt.Errorf("bridge parent did not authorize this connection")
	}
	conn.SetReadDeadline(time.Time{})
	system := bridgeSystemDirectory()
	cmd := exec.Command(system+`\WindowsPowerShell\v1.0\powershell.exe`, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", bridgeBootstrap)
	cmd.Env = []string{"SystemRoot=" + system[:len(system)-9], "WINDIR=" + system[:len(system)-9], "SystemDrive=" + system[:2], "OS=Windows_NT", "PROCESSOR_ARCHITECTURE=AMD64", "PATH=" + system, "PATHEXT=.COM;.EXE;.BAT;.CMD", "COMSPEC=" + system + `\cmd.exe`, "PSModulePath=" + system + `\WindowsPowerShell\v1.0\Modules`, "SESSIONNAME=" + os.Getenv("SESSIONNAME"), "SSH_CONNECTION=" + os.Getenv("SSH_CONNECTION"), "SSH_CLIENT=" + os.Getenv("SSH_CLIENT")}
	configureDiskTool(cmd)
	cmd.Stdout = conn
	var errors diskToolErrors
	cmd.Stderr = &errors
	stdin, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	assets := map[string]string{}
	entries, e := payload.Files.ReadDir(".")
	if e != nil {
		return e
	}
	for _, entry := range entries {
		data, e := payload.Files.ReadFile(entry.Name())
		if e != nil {
			return e
		}
		assets[entry.Name()] = base64.StdEncoding.EncodeToString(data)
	}
	if e = cmd.Start(); e != nil {
		return e
	}
	encoder := json.NewEncoder(stdin)
	if e = encoder.Encode(assets); e == nil {
		e = encoder.Encode(map[string]any{"Action": r.Action, "Plan": r.Plan})
	}
	if e != nil {
		stdin.Close()
		cmd.Wait()
		return e
	}
	go func() { io.Copy(stdin, io.LimitReader(reader, 65536)); stdin.Close() }()
	e = cmd.Wait()
	if e != nil {
		fmt.Fprintln(conn, `{"state":"error","error":"Elevated bridge helper failed. Inspect the protected recovery journal."}`)
		return fmt.Errorf("bridge helper: %w: %s", e, errors.String())
	}
	return nil
}

func bridgeSystemDirectory() string {
	var buffer [32768]uint16
	proc := syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemDirectoryW")
	n, _, _ := proc.Call(uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || n >= uintptr(len(buffer)) {
		return `C:\Windows\System32`
	}
	return syscall.UTF16ToString(buffer[:n])
}

func (s *bridgeSession) NoteQemuEnded() {
	if s != nil {
		s.qemuEnded.Store(true)
	}
}
