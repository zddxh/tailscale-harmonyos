package main

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

const backendOwnershipFile = ".tailscale-owner.lock"
const backendOwnedStatus = "BUSY | backend owned by another process"

var errBackendOwned = errors.New("backend owned by another process")

// backendOwnership is an advisory, nonblocking lock shared by the UI and VPN
// processes. The empty lock file is never removed: replacing its inode could
// let two processes lock different files while writing the same state store.
type backendOwnership struct {
	file      *os.File
	directory string
}

func acquireBackendOwnership(stateDir string) (*backendOwnership, error) {
	if stateDir == "" {
		return nil, errors.New("missing state directory")
	}
	directory, err := filepath.Abs(stateDir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	fd, err := unix.Open(filepath.Join(directory, backendOwnershipFile),
		unix.O_RDWR|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "tailscale-backend-ownership")
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, errors.New("invalid ownership file")
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
			return nil, errBackendOwned
		}
		return nil, err
	}
	return &backendOwnership{file: file, directory: directory}, nil
}

func (owner *backendOwnership) close() error {
	if owner == nil || owner.file == nil {
		return nil
	}
	err := owner.file.Close()
	owner.file = nil
	return err
}
