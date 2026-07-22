//go:build android

package main

import "golang.org/x/sys/unix"

// installExclusive atomically publishes a completed temporary file without
// replacing an existing destination. Android's shell SELinux domain denies
// hard-link creation in /data/local/tmp, so use the kernel's no-replace rename
// primitive there.
func installExclusive(source, destination string) error {
	return unix.Renameat2(
		unix.AT_FDCWD, source,
		unix.AT_FDCWD, destination,
		unix.RENAME_NOREPLACE,
	)
}
