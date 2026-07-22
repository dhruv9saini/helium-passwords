package syncstore

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"time"
)

const (
	tlsCAValidity     = 10 * 365 * 24 * time.Hour
	tlsServerValidity = 365 * 24 * time.Hour
	maxPEMBytes       = 1024 * 1024
)

var tlsHostnamePattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)

type TLSIdentityReceipt struct {
	CAFingerprint     string
	ServerFingerprint string
	Hostname          string
	IP                string
	NotAfter          time.Time
}

// CreateTLSCA creates a name-constrained private CA in a new directory. The
// private key is intended to remain on independently held offline media; lm
// receives only the public certificate and a separately issued leaf key.
func CreateTLSCA(outputDir, hostname, address string) (TLSIdentityReceipt, error) {
	hostname, ip, err := validateTLSEndpoint(outputDir, hostname, address)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	serial, err := randomSerial()
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	now := time.Now().UTC().Truncate(time.Second)
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName: "Helium Sync TLS Root for " + hostname,
		},
		NotBefore:                   now.Add(-5 * time.Minute),
		NotAfter:                    now.Add(tlsCAValidity),
		KeyUsage:                    x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid:       true,
		IsCA:                        true,
		MaxPathLen:                  0,
		MaxPathLenZero:              true,
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         []string{hostname},
		ExcludedDNSDomains:          []string{"." + hostname},
		PermittedIPRanges: []*net.IPNet{{
			IP: ip.AsSlice(), Mask: net.CIDRMask(32, 32),
		}},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template,
		&privateKey.PublicKey, privateKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	if err := installNewDirectory(outputDir, func(root string) error {
		if err := writeSyncedFile(filepath.Join(root, "ca-key.pem"), pem.EncodeToMemory(&pem.Block{
			Type: "PRIVATE KEY", Bytes: privateDER,
		}), 0600); err != nil {
			return err
		}
		return writeSyncedFile(filepath.Join(root, "ca-cert.pem"), pem.EncodeToMemory(&pem.Block{
			Type: "CERTIFICATE", Bytes: certificateDER,
		}), 0644)
	}); err != nil {
		return TLSIdentityReceipt{}, err
	}
	return TLSIdentityReceipt{
		CAFingerprint: certificateFingerprint(certificateDER),
		Hostname:      hostname, IP: ip.String(), NotAfter: template.NotAfter,
	}, nil
}

// IssueTLSServer creates a new server leaf and key under an existing offline
// CA. Both the CA constraints and leaf SANs are exact for lm's current
// Tailscale DNS name and IPv4 address.
func IssueTLSServer(caCertPath, caKeyPath, outputDir, hostname, address string) (TLSIdentityReceipt, error) {
	for _, path := range []string{caCertPath, caKeyPath} {
		if err := requireTLSAbsolutePath(path); err != nil {
			return TLSIdentityReceipt{}, err
		}
	}
	hostname, ip, err := validateTLSEndpoint(outputDir, hostname, address)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	ca, err := readPEMCertificate(caCertPath)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	caKey, err := readECDSAPrivateKey(caKeyPath)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := validateTLSCA(ca, caKey, hostname, ip, now, tlsServerValidity); err != nil {
		return TLSIdentityReceipt{}, err
	}
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	serial, err := randomSerial()
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: hostname},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(tlsServerValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{hostname},
		IPAddresses:           []net.IP{ip.AsSlice()},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, ca,
		&serverKey.PublicKey, caKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(serverKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	if err := installNewDirectory(outputDir, func(root string) error {
		if err := writeSyncedFile(filepath.Join(root, "server-key.pem"), pem.EncodeToMemory(&pem.Block{
			Type: "PRIVATE KEY", Bytes: privateDER,
		}), 0600); err != nil {
			return err
		}
		return writeSyncedFile(filepath.Join(root, "server-cert.pem"), pem.EncodeToMemory(&pem.Block{
			Type: "CERTIFICATE", Bytes: certificateDER,
		}), 0644)
	}); err != nil {
		return TLSIdentityReceipt{}, err
	}
	return TLSIdentityReceipt{
		CAFingerprint:     certificateFingerprint(ca.Raw),
		ServerFingerprint: certificateFingerprint(certificateDER),
		Hostname:          hostname, IP: ip.String(), NotAfter: template.NotAfter,
	}, nil
}

// VerifyTLSServer requires the exact offline root, leaf, private key, endpoint
// identity, and remaining lifetime. It accepts no ambient or alternate root.
func VerifyTLSServer(caCertPath, serverCertPath, serverKeyPath, hostname, address string, minimumValidity time.Duration) (TLSIdentityReceipt, error) {
	for _, path := range []string{caCertPath, serverCertPath, serverKeyPath} {
		if err := requireTLSAbsolutePath(path); err != nil {
			return TLSIdentityReceipt{}, err
		}
	}
	if minimumValidity <= 0 || minimumValidity > tlsServerValidity {
		return TLSIdentityReceipt{}, errors.New("minimum TLS validity must be positive and no more than 365 days")
	}
	hostname, ip, err := validateTLSEndpoint("/absolute/validation-target", hostname, address)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	ca, err := readPEMCertificate(caCertPath)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	server, err := readPEMCertificate(serverCertPath)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	serverKey, err := readECDSAPrivateKey(serverKeyPath)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	now := time.Now().UTC()
	if err := validateTLSCA(ca, nil, hostname, ip, now, minimumValidity); err != nil {
		return TLSIdentityReceipt{}, err
	}
	if server.IsCA || !server.BasicConstraintsValid ||
		server.KeyUsage != x509.KeyUsageDigitalSignature ||
		!reflect.DeepEqual(server.ExtKeyUsage, []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}) ||
		!reflect.DeepEqual(server.DNSNames, []string{hostname}) ||
		len(server.IPAddresses) != 1 || !server.IPAddresses[0].Equal(ip.AsSlice()) {
		return TLSIdentityReceipt{}, errors.New("TLS server certificate purpose or endpoint identity is not exact")
	}
	if now.Before(server.NotBefore) || !server.NotAfter.After(now.Add(minimumValidity)) {
		return TLSIdentityReceipt{}, errors.New("TLS server certificate is not currently valid for the required minimum lifetime")
	}
	if server.NotAfter.Sub(server.NotBefore) > tlsServerValidity+10*time.Minute {
		return TLSIdentityReceipt{}, errors.New("TLS server certificate lifetime exceeds 365 days")
	}
	if err := server.CheckSignatureFrom(ca); err != nil {
		return TLSIdentityReceipt{}, fmt.Errorf("verify TLS server issuer: %w", err)
	}
	serverPublic, err := x509.MarshalPKIXPublicKey(server.PublicKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	keyPublic, err := x509.MarshalPKIXPublicKey(&serverKey.PublicKey)
	if err != nil {
		return TLSIdentityReceipt{}, err
	}
	if !bytes.Equal(serverPublic, keyPublic) {
		return TLSIdentityReceipt{}, errors.New("TLS server certificate and private key do not match")
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	for _, identity := range []string{hostname, ip.String()} {
		if _, err := server.Verify(x509.VerifyOptions{
			Roots: roots, DNSName: identity,
			KeyUsages:   []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			CurrentTime: now,
		}); err != nil {
			return TLSIdentityReceipt{}, fmt.Errorf("verify TLS server identity %q: %w", identity, err)
		}
	}
	return TLSIdentityReceipt{
		CAFingerprint:     certificateFingerprint(ca.Raw),
		ServerFingerprint: certificateFingerprint(server.Raw),
		Hostname:          hostname, IP: ip.String(), NotAfter: server.NotAfter,
	}, nil
}

func validateTLSEndpoint(outputDir, hostname, address string) (string, netip.Addr, error) {
	if err := requireTLSAbsolutePath(outputDir); err != nil {
		return "", netip.Addr{}, err
	}
	hostname = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(hostname), "."))
	if len(hostname) > 253 || !strings.HasSuffix(hostname, ".ts.net") ||
		!tlsHostnamePattern.MatchString(hostname) {
		return "", netip.Addr{}, errors.New("TLS hostname must be a canonical Tailscale .ts.net name")
	}
	ip, err := netip.ParseAddr(strings.TrimSpace(address))
	if err != nil || !ip.Is4() || !netip.MustParsePrefix("100.64.0.0/10").Contains(ip) {
		return "", netip.Addr{}, errors.New("TLS address must be a Tailscale IPv4 address in 100.64.0.0/10")
	}
	return hostname, ip, nil
}

func validateTLSCA(certificate *x509.Certificate, privateKey *ecdsa.PrivateKey,
	hostname string, ip netip.Addr, now time.Time, minimumValidity time.Duration) error {
	if !certificate.IsCA || !certificate.BasicConstraintsValid ||
		certificate.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageCRLSign ||
		!certificate.MaxPathLenZero || certificate.MaxPathLen != 0 ||
		!certificate.PermittedDNSDomainsCritical ||
		!reflect.DeepEqual(certificate.PermittedDNSDomains, []string{hostname}) ||
		!reflect.DeepEqual(certificate.ExcludedDNSDomains, []string{"." + hostname}) ||
		len(certificate.PermittedIPRanges) != 1 ||
		!certificate.PermittedIPRanges[0].IP.Equal(ip.AsSlice()) ||
		!bytes.Equal(certificate.PermittedIPRanges[0].Mask, net.CIDRMask(32, 32)) {
		return errors.New("TLS CA is not an exact path-zero endpoint-constrained root")
	}
	if now.Before(certificate.NotBefore) || !certificate.NotAfter.After(now.Add(minimumValidity)) {
		return errors.New("TLS CA is not currently valid for the required minimum lifetime")
	}
	if err := certificate.CheckSignatureFrom(certificate); err != nil {
		return fmt.Errorf("verify self-signed TLS CA: %w", err)
	}
	if privateKey != nil {
		certificatePublic, err := x509.MarshalPKIXPublicKey(certificate.PublicKey)
		if err != nil {
			return err
		}
		keyPublic, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
		if err != nil {
			return err
		}
		if !bytes.Equal(certificatePublic, keyPublic) {
			return errors.New("TLS CA certificate and private key do not match")
		}
	}
	return nil
}

func readPEMCertificate(path string) (*x509.Certificate, error) {
	raw, err := readRegularFile(path)
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, fmt.Errorf("certificate file must contain exactly one PEM certificate: %s", path)
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse TLS certificate %s: %w", path, err)
	}
	return certificate, nil
}

func readECDSAPrivateKey(path string) (*ecdsa.PrivateKey, error) {
	file, err := openSecretFile(path)
	if err != nil {
		return nil, err
	}
	raw, readErr := io.ReadAll(io.LimitReader(file, maxPEMBytes+1))
	closeErr := file.Close()
	if readErr != nil {
		return nil, readErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if len(raw) > maxPEMBytes {
		return nil, errors.New("TLS private key file is too large")
	}
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "PRIVATE KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("TLS private key must contain exactly one PKCS#8 PEM key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse TLS private key: %w", err)
	}
	privateKey, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || privateKey.Curve != elliptic.P256() {
		return nil, errors.New("TLS private key must be ECDSA P-256")
	}
	return privateKey, nil
}

func readRegularFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxPEMBytes {
		return nil, fmt.Errorf("TLS public file must be regular and no larger than 1 MiB: %s", path)
	}
	return os.ReadFile(path)
}

func requireTLSAbsolutePath(path string) error {
	if strings.TrimSpace(path) == "" || !filepath.IsAbs(path) {
		return fmt.Errorf("TLS path must be absolute: %s", path)
	}
	return nil
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, err
	}
	if serial.Sign() == 0 {
		return big.NewInt(1), nil
	}
	return serial, nil
}

func certificateFingerprint(raw []byte) string {
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}
