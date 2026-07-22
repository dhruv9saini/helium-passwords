package main

import (
	"crypto/tls"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

func TestServerTLSConfigRequiresTLSOffLoopback(t *testing.T) {
	if config, enabled, err := serverTLSConfig("127.0.0.1:44719", "", ""); err != nil || enabled || config != nil {
		t.Fatalf("loopback development listener failed: config=%v enabled=%v err=%v",
			config, enabled, err)
	}
	for name, listen := range map[string]string{
		"tailnet":  "100.100.105.47:44719",
		"wildcard": "0.0.0.0:44719",
		"hostname": "lm.tail0168aa.ts.net:44719",
	} {
		if _, _, err := serverTLSConfig(listen, "", ""); err == nil {
			t.Fatalf("%s listener accepted without TLS", name)
		}
	}
}

func TestServerTLSConfigLoadsExactTailnetIdentity(t *testing.T) {
	root := t.TempDir()
	caDir := filepath.Join(root, "ca")
	serverDir := filepath.Join(root, "server")
	hostname := "lm.tail0168aa.ts.net"
	address := "100.100.105.47"
	if _, err := syncstore.CreateTLSCA(caDir, hostname); err != nil {
		t.Fatal(err)
	}
	if _, err := syncstore.IssueTLSServer(
		filepath.Join(caDir, "ca-cert.pem"), filepath.Join(caDir, "ca-key.pem"),
		serverDir, hostname, address); err != nil {
		t.Fatal(err)
	}
	certificate := filepath.Join(serverDir, "server-cert.pem")
	key := filepath.Join(serverDir, "server-key.pem")
	config, enabled, err := serverTLSConfig(address+":44719", certificate, key)
	if err != nil {
		t.Fatal(err)
	}
	if !enabled || config.MinVersion != tls.VersionTLS13 || len(config.Certificates) != 1 {
		t.Fatalf("unexpected TLS config: enabled=%v config=%+v", enabled, config)
	}
	if _, _, err := serverTLSConfig("100.100.105.48:44719", certificate, key); err == nil ||
		!strings.Contains(err.Error(), "does not cover") {
		t.Fatalf("wrong listen address was not rejected: %v", err)
	}
	if _, _, err := serverTLSConfig("192.0.2.1:44719", certificate, key); err == nil ||
		!strings.Contains(err.Error(), "Tailscale IPv4") {
		t.Fatalf("public listen address was not rejected: %v", err)
	}

	weakKey := filepath.Join(root, "weak-key.pem")
	raw, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(weakKey, raw, 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := serverTLSConfig(address+":44719", certificate, weakKey); err == nil ||
		!strings.Contains(err.Error(), "service-owned 0600") {
		t.Fatalf("weak key permissions were not rejected: %v", err)
	}
}

func TestTLSKeyPermissionsPermitImmutableServiceReadableKey(t *testing.T) {
	if !tlsKeyPermissions(0600, 1000, 1000, 1000, 1000) {
		t.Fatal("service-owned private key was rejected")
	}
	if !tlsKeyPermissions(0640, 0, 900, 900, 900) {
		t.Fatal("root-owned service-group private key was rejected")
	}
	for name, accepted := range map[string]bool{
		"service writable group": tlsKeyPermissions(0660, 0, 900, 900, 900),
		"other readable":         tlsKeyPermissions(0644, 0, 900, 900, 900),
		"wrong group":            tlsKeyPermissions(0640, 0, 901, 900, 900),
		"service owns 0640":      tlsKeyPermissions(0640, 900, 900, 900, 900),
		"root consumes 0640":     tlsKeyPermissions(0640, 0, 0, 0, 0),
		"foreign 0600":           tlsKeyPermissions(0600, 0, 900, 900, 900),
	} {
		if accepted {
			t.Fatalf("unsafe TLS key mode accepted: %s", name)
		}
	}
}
