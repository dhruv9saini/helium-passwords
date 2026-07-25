package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

func main() {
	var (
		dataDir = flag.String(
			"data-dir", defaultDataDir(), "Helium Sync server data directory")
		devicesFile = flag.String(
			"devices-file",
			envOrDefault("HELIUM_SYNC_DEVICES_FILE",
				filepath.Join(defaultDataDir(), "devices.json")),
			"hashed per-device registry")
		listen = flag.String(
			"listen",
			envOrDefault("HELIUM_SYNC_LISTEN", "127.0.0.1:44719"),
			"exact loopback or Tailscale IPv4 listen address")
	)
	flag.Parse()
	if err := validateListen(*listen); err != nil {
		fail(err)
	}

	store, err := syncstore.OpenStore(*dataDir)
	if err != nil {
		fail(err)
	}
	registry, err := syncstore.OpenDeviceRegistry(*devicesFile)
	if err != nil {
		fail(err)
	}

	server := &http.Server{
		Addr: *listen, Handler: syncstore.NewHandler(store, registry),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	go func() {
		slog.Info("helium-syncd listening",
			"addr", *listen, "data_dir", *dataDir)
		if err := server.ListenAndServe(); err != nil &&
			!errors.Is(err, http.ErrServerClosed) {
			fail(err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		fail(err)
	}
}

func validateListen(listen string) error {
	host, port, err := net.SplitHostPort(listen)
	if err != nil || host == "" || port == "" {
		return errors.New(
			"listen address must contain an explicit IP and port")
	}
	address, err := netip.ParseAddr(host)
	if err != nil {
		return errors.New(
			"listen address must use an IP, not a hostname or wildcard")
	}
	if !address.IsLoopback() &&
		(!address.Is4() ||
			!netip.MustParsePrefix("100.64.0.0/10").Contains(address)) {
		return errors.New(
			"listener must use loopback or a Tailscale IPv4 address")
	}
	return nil
}

func defaultDataDir() string {
	if value := os.Getenv("HELIUM_SYNC_DATA_DIR"); value != "" {
		return value
	}
	if value := os.Getenv("XDG_DATA_HOME"); value != "" {
		return filepath.Join(value, "helium-sync")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".helium-sync"
	}
	return filepath.Join(home, ".local", "share", "helium-sync")
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
