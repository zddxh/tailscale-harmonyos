package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func TestBackendOwnershipRejectsSecondEngine(t *testing.T) {
	dir := t.TempDir()
	owner, err := acquireBackendOwnership(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.close()
	var contender backendController
	if got := contender.start(dir, "test"); got != backendOwnedStatus {
		t.Fatalf("second backend start = %q, want %q", got, backendOwnedStatus)
	}
	if contender.server != nil || contender.client != nil || contender.starting {
		t.Fatal("contending process initialized a backend before acquiring ownership")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 || entries[0].Name() != backendOwnershipFile {
		t.Fatalf("contender touched persistent backend state: entries=%v err=%v", entries, err)
	}
}

func TestBackendOwnershipStopWaitsForStartup(t *testing.T) {
	dir := t.TempDir()
	owner, err := acquireBackendOwnership(dir)
	if err != nil {
		t.Fatal(err)
	}
	startupDone := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	backend := backendController{ownership: owner, startDone: startupDone, cancelStart: cancel}
	t.Cleanup(func() {
		select {
		case <-startupDone:
		default:
			close(startupDone)
		}
	})
	stopped := make(chan string, 1)
	go func() { stopped <- backend.stop() }()
	select {
	case <-ctx.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("stop failed to cancel pending startup")
	}
	select {
	case result := <-stopped:
		t.Fatalf("stop returned before startup completed: %s", result)
	case <-time.After(50 * time.Millisecond):
	}
	if extra, err := acquireBackendOwnership(dir); !errors.Is(err, errBackendOwned) {
		if extra != nil {
			extra.close()
		}
		t.Fatalf("ownership released while startup could still write: %v", err)
	}
	close(startupDone)
	select {
	case got := <-stopped:
		if got != "OK | backend stopped" {
			t.Fatal(got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("stop did not complete after startup finished")
	}
	replacement, err := acquireBackendOwnership(dir)
	if err != nil {
		t.Fatalf("ownership not released by stop: %v", err)
	}
	defer replacement.close()
}

func TestBackendOwnershipCloseFailureRetainsLock(t *testing.T) {
	dir := t.TempDir()
	owner, err := acquireBackendOwnership(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.close()
	// A server whose initialization failed before creating its system cannot
	// be cleanly closed. This exercises the fail-closed partial-startup path.
	backend := backendController{server: &tsnet.Server{}, ownership: owner}
	if got := backend.stop(); got != "FAILED | backend stop" {
		t.Fatalf("unexpected close result: %q", got)
	}
	if other, err := acquireBackendOwnership(dir); !errors.Is(err, errBackendOwned) {
		if other != nil {
			other.close()
		}
		t.Fatalf("close failure released ownership too early: %v", err)
	}
}

func TestBackendOwnershipIndependentProcesses(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	holder := ownershipHelper(ctx, dir, "hold")
	stdout, err := holder.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := holder.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if holder.ProcessState == nil {
			_ = holder.Process.Kill()
			_ = holder.Wait()
		}
	})
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil || line != "locked\n" {
		t.Fatalf("helper failed to acquire lock: %q %v", line, err)
	}
	output, err := ownershipHelper(ctx, dir, "try").CombinedOutput()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 23 || !strings.Contains(string(output), "busy") {
		t.Fatalf("independent process was not excluded: output=%q error=%v", output, err)
	}
	if err := holder.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = holder.Wait()
	output, err = ownershipHelper(ctx, dir, "try").CombinedOutput()
	if err != nil || !strings.Contains(string(output), "acquired") {
		t.Fatalf("kernel did not release ownership on process death: output=%q error=%v", output, err)
	}
	if _, err := os.Stat(filepath.Join(dir, backendOwnershipFile)); err != nil {
		t.Fatalf("lock inode must remain after release: %v", err)
	}
}

func TestBackendOwnershipRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "untouched")
	if err := os.WriteFile(target, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, backendOwnershipFile)); err != nil {
		t.Fatal(err)
	}
	if owner, err := acquireBackendOwnership(dir); err == nil {
		owner.close()
		t.Fatal("followed ownership-file symlink")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "unchanged" {
		t.Fatalf("symlink target changed: %q %v", data, err)
	}
}

func ownershipHelper(ctx context.Context, dir, mode string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestBackendOwnershipHelper$")
	cmd.Env = append(os.Environ(), "TS_TEST_OWNERSHIP_DIR="+dir, "TS_TEST_OWNERSHIP_MODE="+mode)
	return cmd
}

func TestBackendOwnershipHelper(t *testing.T) {
	mode := os.Getenv("TS_TEST_OWNERSHIP_MODE")
	if mode == "" {
		return
	}
	owner, err := acquireBackendOwnership(os.Getenv("TS_TEST_OWNERSHIP_DIR"))
	if errors.Is(err, errBackendOwned) {
		fmt.Println("busy")
		os.Exit(23)
	}
	if err != nil {
		fmt.Println("lock failed")
		os.Exit(24)
	}
	if mode == "hold" {
		fmt.Println("locked")
		// Keep ownership until killed by the parent without an explicit unlock.
		time.Sleep(30 * time.Second)
	}
	owner.close()
	fmt.Println("acquired")
}
