package syncstore

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTLSIdentityLifecycleAndHandshake(t *testing.T) {
	root := t.TempDir()
	hostname := "lm.tail0168aa.ts.net"
	address := "100.100.105.47"
	caDir := filepath.Join(root, "offline-ca")
	serverDir := filepath.Join(root, "lm-generation")

	caReceipt, err := CreateTLSCA(caDir, hostname, address)
	if err != nil {
		t.Fatal(err)
	}
	if len(caReceipt.CAFingerprint) != 64 || caReceipt.ServerFingerprint != "" {
		t.Fatalf("unexpected CA receipt: %+v", caReceipt)
	}
	assertMode(t, filepath.Join(caDir, "ca-key.pem"), 0600)
	assertMode(t, filepath.Join(caDir, "ca-cert.pem"), 0644)
	assertCARejectsSubdomain(t, caDir, hostname)

	issued, err := IssueTLSServer(
		filepath.Join(caDir, "ca-cert.pem"), filepath.Join(caDir, "ca-key.pem"),
		serverDir, hostname, address)
	if err != nil {
		t.Fatal(err)
	}
	if issued.CAFingerprint != caReceipt.CAFingerprint ||
		len(issued.ServerFingerprint) != 64 {
		t.Fatalf("unexpected server receipt: %+v", issued)
	}
	assertMode(t, filepath.Join(serverDir, "server-key.pem"), 0600)
	assertMode(t, filepath.Join(serverDir, "server-cert.pem"), 0644)

	verified, err := VerifyTLSServer(
		filepath.Join(caDir, "ca-cert.pem"),
		filepath.Join(serverDir, "server-cert.pem"),
		filepath.Join(serverDir, "server-key.pem"), hostname, address, 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if verified != issued {
		t.Fatalf("verify receipt differs from issuance: got %+v want %+v", verified, issued)
	}

	keyPair, err := tls.LoadX509KeyPair(
		filepath.Join(serverDir, "server-cert.pem"),
		filepath.Join(serverDir, "server-key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(response, "ok")
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{keyPair}, MinVersion: tls.VersionTLS13}
	server.StartTLS()
	defer server.Close()

	caPEM, err := os.ReadFile(filepath.Join(caDir, "ca-cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		t.Fatal("could not load generated CA")
	}
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: hostname, MinVersion: tls.VersionTLS13},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
		},
	}
	client := &http.Client{Transport: transport, Timeout: time.Second}
	response, err := client.Get("https://" + hostname + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "ok" {
		t.Fatalf("unexpected TLS response %q: %v", body, err)
	}
}

func TestTLSIdentityFailsClosed(t *testing.T) {
	root := t.TempDir()
	hostname := "lm.tail0168aa.ts.net"
	address := "100.100.105.47"
	caDir := filepath.Join(root, "ca")
	serverDir := filepath.Join(root, "server")
	if _, err := CreateTLSCA(caDir, hostname, address); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateTLSCA(caDir, hostname, address); err == nil {
		t.Fatal("CA creation replaced an existing directory")
	}
	if _, err := IssueTLSServer(filepath.Join(caDir, "ca-cert.pem"),
		filepath.Join(caDir, "ca-key.pem"), serverDir, hostname, address); err != nil {
		t.Fatal(err)
	}
	secondServerDir := filepath.Join(root, "second-server")
	if _, err := IssueTLSServer(filepath.Join(caDir, "ca-cert.pem"),
		filepath.Join(caDir, "ca-key.pem"), secondServerDir, hostname, address); err != nil {
		t.Fatal(err)
	}

	verify := func(host, ip, keyPath string, validity time.Duration) error {
		_, err := VerifyTLSServer(filepath.Join(caDir, "ca-cert.pem"),
			filepath.Join(serverDir, "server-cert.pem"), keyPath,
			host, ip, validity)
		return err
	}
	for name, err := range map[string]error{
		"wrong hostname": verify("other.tail0168aa.ts.net", address,
			filepath.Join(serverDir, "server-key.pem"), 24*time.Hour),
		"wrong address": verify(hostname, "100.100.105.48",
			filepath.Join(serverDir, "server-key.pem"), 24*time.Hour),
		"excess lifetime": verify(hostname, address,
			filepath.Join(serverDir, "server-key.pem"), 365*24*time.Hour),
		"mismatched key": verify(hostname, address,
			filepath.Join(secondServerDir, "server-key.pem"), 24*time.Hour),
	} {
		if err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
	otherCADir := filepath.Join(root, "other-ca")
	if _, err := CreateTLSCA(otherCADir, hostname, address); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyTLSServer(filepath.Join(otherCADir, "ca-cert.pem"),
		filepath.Join(serverDir, "server-cert.pem"),
		filepath.Join(serverDir, "server-key.pem"), hostname, address,
		24*time.Hour); err == nil {
		t.Fatal("server certificate was accepted under a substituted root")
	}

	weakKey := filepath.Join(root, "weak-key.pem")
	raw, err := os.ReadFile(filepath.Join(serverDir, "server-key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(weakKey, raw, 0644); err != nil {
		t.Fatal(err)
	}
	if err := verify(hostname, address, weakKey, 24*time.Hour); err == nil ||
		!strings.Contains(err.Error(), "mode 0600") {
		t.Fatalf("weak key permissions were not rejected: %v", err)
	}

	if _, err := CreateTLSCA(filepath.Join(root, "public-address"), hostname,
		"192.0.2.1"); err == nil {
		t.Fatal("non-Tailscale address was accepted")
	}
	if _, err := CreateTLSCA(filepath.Join(root, "public-host"),
		"example.com", address); err == nil {
		t.Fatal("non-Tailscale hostname was accepted")
	}
}

func assertMode(t *testing.T, path string, expected os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != expected {
		t.Fatalf("%s mode = %04o, want %04o", path, info.Mode().Perm(), expected)
	}
}

func assertCARejectsSubdomain(t *testing.T, caDir, hostname string) {
	t.Helper()
	ca, err := readPEMCertificate(filepath.Join(caDir, "ca-cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	caKey, err := readECDSAPrivateKey(filepath.Join(caDir, "ca-key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, err := randomSerial()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	der, err := x509.CreateCertificate(rand.Reader, &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "sub." + hostname},
		NotBefore:    now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"sub." + hostname},
	}, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots: roots, DNSName: "sub." + hostname,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}); err == nil {
		t.Fatal("CA name constraints allowed a subdomain of the lm endpoint")
	}
}
