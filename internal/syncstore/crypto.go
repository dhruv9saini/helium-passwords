package syncstore

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	configVersion   = 1
	defaultKDF      = "pbkdf2-sha256"
	defaultIters    = 210000
	keyLength       = 32
	saltLength      = 16
	nonceLength     = 12
	emptyJSONObject = "{}"
)

type Config struct {
	Version          int       `json:"version"`
	KDF              string    `json:"kdf"`
	PBKDF2Iterations int       `json:"pbkdf2_iterations"`
	Salt             string    `json:"salt"`
	CreatedAt        time.Time `json:"created_at"`
}

func newConfig() (Config, error) {
	salt := make([]byte, saltLength)
	if _, err := rand.Read(salt); err != nil {
		return Config{}, err
	}
	return Config{
		Version:          configVersion,
		KDF:              defaultKDF,
		PBKDF2Iterations: defaultIters,
		Salt:             base64.StdEncoding.EncodeToString(salt),
		CreatedAt:        time.Now().UTC(),
	}, nil
}

func newAEAD(config Config, passphrase string) (cipher.AEAD, error) {
	if passphrase == "" {
		return nil, errors.New("passphrase is required")
	}
	if config.Version != configVersion {
		return nil, fmt.Errorf("unsupported config version %d", config.Version)
	}
	if config.KDF != defaultKDF {
		return nil, fmt.Errorf("unsupported kdf %q", config.KDF)
	}
	salt, err := base64.StdEncoding.DecodeString(config.Salt)
	if err != nil {
		return nil, fmt.Errorf("decode salt: %w", err)
	}
	if len(salt) < 8 {
		return nil, errors.New("salt is too short")
	}
	key, err := pbkdf2.Key(sha256.New, passphrase, salt, config.PBKDF2Iterations, keyLength)
	if err != nil {
		return nil, fmt.Errorf("derive key: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create cipher: %w", err)
	}
	return cipher.NewGCM(block)
}

type aadRecord struct {
	Seq          int64     `json:"seq"`
	Kind         Kind      `json:"kind"`
	Key          string    `json:"key"`
	Version      int64     `json:"version"`
	UpdatedAt    time.Time `json:"updated_at"`
	Deleted      bool      `json:"deleted"`
	OriginDevice string    `json:"origin_device"`
}

func aadFor(record StoredRecord) ([]byte, error) {
	return json.Marshal(aadRecord{
		Seq:          record.Seq,
		Kind:         record.Kind,
		Key:          record.Key,
		Version:      record.Version,
		UpdatedAt:    record.UpdatedAt,
		Deleted:      record.Deleted,
		OriginDevice: record.OriginDevice,
	})
}

func encryptRecord(aead cipher.AEAD, record StoredRecord, payload []byte) (StoredRecord, error) {
	if len(payload) == 0 {
		payload = []byte(emptyJSONObject)
	}
	nonce := make([]byte, nonceLength)
	if _, err := rand.Read(nonce); err != nil {
		return StoredRecord{}, err
	}
	aad, err := aadFor(record)
	if err != nil {
		return StoredRecord{}, err
	}
	ciphertext := aead.Seal(nil, nonce, payload, aad)
	record.Nonce = base64.StdEncoding.EncodeToString(nonce)
	record.Ciphertext = base64.StdEncoding.EncodeToString(ciphertext)
	return record, nil
}

func decryptRecord(aead cipher.AEAD, record StoredRecord) ([]byte, error) {
	nonce, err := base64.StdEncoding.DecodeString(record.Nonce)
	if err != nil {
		return nil, fmt.Errorf("decode nonce: %w", err)
	}
	if len(nonce) != nonceLength {
		return nil, fmt.Errorf("invalid nonce length %d", len(nonce))
	}
	ciphertext, err := base64.StdEncoding.DecodeString(record.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("decode ciphertext: %w", err)
	}
	aad, err := aadFor(record)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, fmt.Errorf("decrypt seq %d: %w", record.Seq, err)
	}
	return plaintext, nil
}
