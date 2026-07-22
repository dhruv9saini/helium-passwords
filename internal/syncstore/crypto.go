package syncstore

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	clientKeyLength   = 32
	clientNonceLength = 12
)

func encryptClientPayload(key []byte, deviceID, keyID string, mutation PlainMutation, revision Counter) (OpaqueMutation, error) {
	if len(key) != clientKeyLength {
		return OpaqueMutation{}, errors.New("client encryption key must be 32 bytes")
	}
	if strings.TrimSpace(mutation.Key) == "" {
		return OpaqueMutation{}, errors.New("record key is required")
	}
	if _, ok := allKinds[mutation.Kind]; !ok {
		return OpaqueMutation{}, fmt.Errorf("unknown record kind %q", mutation.Kind)
	}
	if !json.Valid(mutation.Payload) {
		return OpaqueMutation{}, errors.New("payload must be valid JSON")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return OpaqueMutation{}, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return OpaqueMutation{}, err
	}
	nonce := make([]byte, clientNonceLength)
	if _, err := rand.Read(nonce); err != nil {
		return OpaqueMutation{}, err
	}
	aad, err := canonicalPayloadAAD(mutation.Kind, mutation.Key, revision, mutation.Deleted, deviceID, keyID)
	if err != nil {
		return OpaqueMutation{}, err
	}
	return OpaqueMutation{
		Kind: mutation.Kind, Key: mutation.Key, ExpectedRevision: revision - 1,
		Deleted: mutation.Deleted, KeyID: keyID,
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(aead.Seal(nil, nonce, mutation.Payload, aad)),
	}, nil
}

func decryptClientPayload(key []byte, record OpaqueRecord) (json.RawMessage, error) {
	if len(key) != clientKeyLength {
		return nil, errors.New("client encryption key must be 32 bytes")
	}
	nonce, err := base64.StdEncoding.DecodeString(record.Nonce)
	if err != nil || len(nonce) != clientNonceLength {
		return nil, errors.New("invalid record nonce")
	}
	ciphertext, err := base64.StdEncoding.DecodeString(record.Ciphertext)
	if err != nil {
		return nil, errors.New("invalid record ciphertext encoding")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	aad, err := canonicalPayloadAAD(record.Kind, record.Key, record.Revision, record.Deleted, record.DeviceID, record.KeyID)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, fmt.Errorf("authenticate %s/%s revision %d: %w", record.Kind, record.Key, record.Revision, err)
	}
	if !json.Valid(plaintext) {
		return nil, errors.New("authenticated payload is not valid JSON")
	}
	return json.RawMessage(plaintext), nil
}

// canonicalPayloadAAD is the cross-language v2 wire format. It is deliberately
// not JSON. Bytes are: ASCII magic including NUL; kind, key, device_id, and
// key_id as uint32-be byte length followed by UTF-8 bytes; revision as uint64-be;
// deleted as exactly 0x00 or 0x01. Go and Chromium implementations must share
// test vectors for this exact sequence.
func canonicalPayloadAAD(kind Kind, key string, revision Counter, deleted bool, deviceID, keyID string) ([]byte, error) {
	if revision <= 0 {
		return nil, errors.New("revision must be positive")
	}
	var buffer bytes.Buffer
	buffer.WriteString("helium-sync-e2ee-v2\x00")
	for _, value := range []string{string(kind), key, deviceID, keyID} {
		if uint64(len(value)) > uint64(^uint32(0)) {
			return nil, errors.New("AAD field is too large")
		}
		if err := binary.Write(&buffer, binary.BigEndian, uint32(len(value))); err != nil {
			return nil, err
		}
		buffer.WriteString(value)
	}
	if err := binary.Write(&buffer, binary.BigEndian, uint64(revision)); err != nil {
		return nil, err
	}
	if deleted {
		buffer.WriteByte(1)
	} else {
		buffer.WriteByte(0)
	}
	return buffer.Bytes(), nil
}
