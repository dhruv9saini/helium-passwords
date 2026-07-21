package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

func main() {
	var (
		dataDir        = flag.String("data-dir", defaultDataDir(), "helium-sync data directory")
		passphraseFile = flag.String("passphrase-file", envOrDefault("HELIUM_SYNC_PASSPHRASE_FILE", filepath.Join(defaultDataDir(), "passphrase")), "passphrase file")
		tokenFile      = flag.String("token-file", envOrDefault("HELIUM_SYNC_TOKEN_FILE", filepath.Join(defaultDataDir(), "token")), "daemon token file")
		listen         = flag.String("listen", envOrDefault("HELIUM_SYNC_LISTEN", "127.0.0.1:44719"), "listen address")
	)
	flag.Parse()

	passphrase, err := readSecret(*passphraseFile)
	if err != nil {
		fail(err)
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		fail(err)
	}
	store, err := syncstore.OpenStore(*dataDir, passphrase)
	if err != nil {
		fail(err)
	}

	server := &http.Server{
		Addr:              *listen,
		Handler:           syncstore.NewHandler(store, syncstore.HandlerOptions{Token: token}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		slog.Info("helium-syncd listening", "addr", *listen, "data_dir", *dataDir)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
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

func readSecret(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	secret := strings.TrimSpace(string(raw))
	if secret == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return secret, nil
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
