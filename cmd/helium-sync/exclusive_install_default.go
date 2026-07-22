//go:build !android

package main

import "os"

func installExclusive(source, destination string) error {
	return os.Link(source, destination)
}
