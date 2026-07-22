package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
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
		dataDir     = flag.String("data-dir", defaultDataDir(), "helium-sync opaque server data directory")
		devicesFile = flag.String("devices-file", envOrDefault("HELIUM_SYNC_DEVICES_FILE", filepath.Join(defaultDataDir(), "devices.json")), "hashed per-device registry")
		listen      = flag.String("listen", envOrDefault("HELIUM_SYNC_LISTEN", "127.0.0.1:44719"), "listen address")
		tlsCertFile = flag.String("tls-cert-file", envOrDefault("HELIUM_SYNC_TLS_CERT_FILE", ""), "TLS server certificate")
		tlsKeyFile  = flag.String("tls-key-file", envOrDefault("HELIUM_SYNC_TLS_KEY_FILE", ""), "TLS server private key")
	)
	flag.Parse()
	tlsConfig, tlsEnabled, err := serverTLSConfig(*listen, *tlsCertFile, *tlsKeyFile)
	if err != nil {
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
		Addr:              *listen,
		Handler:           syncstore.NewHandler(store, registry),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
		TLSConfig:         tlsConfig,
	}
	go func() {
		slog.Info("helium-syncd listening", "addr", *listen, "data_dir", *dataDir,
			"tls", tlsEnabled)
		var err error
		if tlsEnabled {
			err = server.ListenAndServeTLS("", "")
		} else {
			err = server.ListenAndServe()
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
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

func serverTLSConfig(listen, certificatePath, keyPath string) (*tls.Config, bool, error) {
	host, _, err := net.SplitHostPort(listen)
	if err != nil || host == "" {
		return nil, false, errors.New("listen address must contain an explicit IP and port")
	}
	parsedAddress, err := netip.ParseAddr(host)
	if err != nil {
		return nil, false, errors.New("listen address must use an IP, not a hostname or wildcard")
	}
	if !parsedAddress.IsLoopback() &&
		(!parsedAddress.Is4() || !netip.MustParsePrefix("100.64.0.0/10").Contains(parsedAddress)) {
		return nil, false, errors.New("non-loopback listener must use a Tailscale IPv4 address")
	}
	if certificatePath == "" && keyPath == "" {
		if !parsedAddress.IsLoopback() {
			return nil, false, errors.New("non-loopback listeners require TLS")
		}
		return nil, false, nil
	}
	if certificatePath == "" || keyPath == "" {
		return nil, false, errors.New("TLS certificate and private key must be provided together")
	}
	if !filepath.IsAbs(certificatePath) || !filepath.IsAbs(keyPath) {
		return nil, false, errors.New("TLS certificate and private key paths must be absolute")
	}
	keyInfo, err := os.Lstat(keyPath)
	if err != nil {
		return nil, false, err
	}
	keyStat, ok := keyInfo.Sys().(*syscall.Stat_t)
	if !keyInfo.Mode().IsRegular() || !ok || !tlsKeyPermissions(
		keyInfo.Mode().Perm(), keyStat.Uid, keyStat.Gid, uint32(os.Geteuid()), uint32(os.Getegid())) {
		return nil, false, errors.New("TLS private key must be service-owned 0600 or root-owned service-group 0640")
	}
	certificateInfo, err := os.Lstat(certificatePath)
	if err != nil {
		return nil, false, err
	}
	if !certificateInfo.Mode().IsRegular() {
		return nil, false, errors.New("TLS certificate must be a regular file")
	}
	pair, err := tls.LoadX509KeyPair(certificatePath, keyPath)
	if err != nil {
		return nil, false, fmt.Errorf("load TLS identity: %w", err)
	}
	if len(pair.Certificate) != 1 {
		return nil, false, errors.New("TLS certificate file must contain exactly one leaf")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, false, fmt.Errorf("parse TLS server certificate: %w", err)
	}
	now := time.Now()
	if now.Before(leaf.NotBefore) || !leaf.NotAfter.After(now.Add(24*time.Hour)) {
		return nil, false, errors.New("TLS server certificate is not valid for at least 24 hours")
	}
	if err := leaf.VerifyHostname(host); err != nil {
		return nil, false, fmt.Errorf("TLS server certificate does not cover listen address: %w", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS13,
	}, true, nil
}

func tlsKeyPermissions(mode os.FileMode, owner, group, effectiveUID, effectiveGID uint32) bool {
	if mode == 0600 {
		return owner == effectiveUID
	}
	return mode == 0640 && owner == 0 && effectiveUID != 0 && group == effectiveGID
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
