package syncstore

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const clientStateVersion = 1

type EnrollmentBundle struct {
	Version       int               `json:"version"`
	ActiveKeyID   string            `json:"active_key_id"`
	StagedKeyID   string            `json:"staged_key_id"`
	RetiringKeyID string            `json:"retiring_key_id"`
	Keys          map[string]string `json:"keys"`
}

type ClientState struct {
	Version            int                `json:"version"`
	DeviceID           string             `json:"device_id"`
	Role               DeviceRole         `json:"role"`
	Phase              EnrollmentPhase    `json:"phase"`
	ActiveKeyID        string             `json:"active_key_id"`
	StagedKeyID        string             `json:"staged_key_id"`
	RetiringKeyID      string             `json:"retiring_key_id"`
	Keys               map[string]string  `json:"keys"`
	Revisions          map[string]Counter `json:"revisions"`
	Sequence           Counter            `json:"sequence"`
	SeedSigningPublic  string             `json:"seed_signing_public"`
	SeedSigningPrivate string             `json:"seed_signing_private,omitempty"`
	LocalSealKey       string             `json:"local_seal_key"`
	path               string
}

func CreateSeedState(path string) (*ClientState, error) {
	if _, err := os.Stat(path); err == nil {
		return nil, fmt.Errorf("client state already exists: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	keyID, encodedKey, err := newClientKey()
	if err != nil {
		return nil, err
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	_, localSealKey, err := newClientKey()
	if err != nil {
		return nil, err
	}
	state := &ClientState{
		Version: clientStateVersion, DeviceID: "d", Role: RoleSeed, Phase: PhaseActive,
		ActiveKeyID: keyID, Keys: map[string]string{keyID: encodedKey},
		Revisions: make(map[string]Counter), path: path,
		SeedSigningPublic:  base64.StdEncoding.EncodeToString(publicKey),
		SeedSigningPrivate: base64.StdEncoding.EncodeToString(privateKey),
		LocalSealKey:       localSealKey,
	}
	if err := state.Save(); err != nil {
		return nil, err
	}
	return state, nil
}

func createJoinState(path, deviceID, seedSigningPublic string, bundle EnrollmentBundle) (*ClientState, error) {
	if _, err := os.Stat(path); err == nil {
		return nil, fmt.Errorf("client state already exists: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if !validDeviceID.MatchString(deviceID) || deviceID == "d" {
		return nil, errors.New("join device id is invalid or reserved")
	}
	if err := validateEnrollment(bundle); err != nil {
		return nil, err
	}
	_, localSealKey, err := newClientKey()
	if err != nil {
		return nil, err
	}
	state := &ClientState{
		Version: clientStateVersion, DeviceID: deviceID, Role: RoleJoin, Phase: PhasePending,
		ActiveKeyID: bundle.ActiveKeyID, StagedKeyID: bundle.StagedKeyID,
		RetiringKeyID: bundle.RetiringKeyID,
		Keys:          cloneKeys(bundle.Keys),
		Revisions:     make(map[string]Counter), path: path,
		SeedSigningPublic: seedSigningPublic,
		LocalSealKey:      localSealKey,
	}
	if err := state.Save(); err != nil {
		return nil, err
	}
	return state, nil
}

func LoadClientState(path string) (*ClientState, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read client state: %w", err)
	}
	var state ClientState
	if err := strictDecode(raw, &state); err != nil {
		return nil, fmt.Errorf("decode client state: %w", err)
	}
	state.path = path
	if err := state.validate(); err != nil {
		return nil, fmt.Errorf("validate client state: %w", err)
	}
	return &state, nil
}

func (state *ClientState) Save() error {
	if err := state.validate(); err != nil {
		return err
	}
	if strings.TrimSpace(state.path) == "" {
		return errors.New("client state path is required")
	}
	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(state.path, append(raw, '\n'), 0600)
}

func (state *ClientState) EnrollmentBundle() (EnrollmentBundle, error) {
	if state.Role != RoleSeed || state.DeviceID != "d" {
		return EnrollmentBundle{}, errors.New("only d may export enrollment")
	}
	return EnrollmentBundle{
		Version: clientStateVersion, ActiveKeyID: state.ActiveKeyID,
		StagedKeyID:   state.StagedKeyID,
		RetiringKeyID: state.RetiringKeyID,
		Keys:          cloneKeys(state.Keys),
	}, nil
}

func (state *ClientState) revision(kind Kind, key string) Counter {
	return state.Revisions[recordIdentity(kind, key)]
}

func (state *ClientState) decodedKey(keyID string) ([]byte, error) {
	encoded, ok := state.Keys[keyID]
	if !ok {
		return nil, fmt.Errorf("missing encryption key %q", keyID)
	}
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(key) != clientKeyLength {
		return nil, fmt.Errorf("invalid encryption key %q", keyID)
	}
	return key, nil
}

func (state *ClientState) prepareKeyRotation() (string, string, error) {
	if state.Role != RoleSeed || state.DeviceID != "d" {
		return "", "", errors.New("only d may rotate encryption keys")
	}
	return newClientKey()
}

func (state *ClientState) stageKey(keyID, encodedKey string) error {
	if _, exists := state.Keys[keyID]; exists {
		if state.StagedKeyID == keyID {
			return nil
		}
		return errors.New("new encryption key id already exists")
	}
	state.Keys[keyID] = encodedKey
	state.StagedKeyID = keyID
	return state.Save()
}

func (state *ClientState) activateStagedKey() error {
	if state.StagedKeyID == "" || state.Keys[state.StagedKeyID] == "" {
		return errors.New("staged key is missing")
	}
	state.RetiringKeyID = state.ActiveKeyID
	state.ActiveKeyID = state.StagedKeyID
	state.StagedKeyID = ""
	return state.Save()
}

func (state *ClientState) retireOldKey() error {
	if state.RetiringKeyID == "" {
		return errors.New("no retiring key")
	}
	delete(state.Keys, state.RetiringKeyID)
	state.RetiringKeyID = ""
	return state.Save()
}

func (state *ClientState) validate() error {
	if state.Version != clientStateVersion {
		return fmt.Errorf("unsupported version %d", state.Version)
	}
	if !validDeviceID.MatchString(state.DeviceID) {
		return errors.New("invalid device id")
	}
	if state.Role == RoleSeed {
		if state.DeviceID != "d" || state.Phase != PhaseActive {
			return errors.New("only d may have the seed role")
		}
		privateKey, err := base64.StdEncoding.DecodeString(state.SeedSigningPrivate)
		if err != nil || len(privateKey) != ed25519.PrivateKeySize {
			return errors.New("seed signing private key is invalid")
		}
	} else if state.Role != RoleJoin || state.DeviceID == "d" ||
		(state.Phase != PhasePending && state.Phase != PhaseActive) {
		return errors.New("non-d devices must have the join role")
	} else if state.SeedSigningPrivate != "" {
		return errors.New("join state must not contain the seed signing private key")
	}
	publicKey, err := base64.StdEncoding.DecodeString(state.SeedSigningPublic)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return errors.New("seed signing public key is invalid")
	}
	localSealKey, err := base64.StdEncoding.DecodeString(state.LocalSealKey)
	if err != nil || len(localSealKey) != clientKeyLength {
		return errors.New("device-local seal key is invalid")
	}
	if err := validateEnrollment(EnrollmentBundle{
		Version: state.Version, ActiveKeyID: state.ActiveKeyID,
		StagedKeyID: state.StagedKeyID, RetiringKeyID: state.RetiringKeyID,
		Keys: state.Keys,
	}); err != nil {
		return err
	}
	if state.Revisions == nil {
		return errors.New("revisions map is required")
	}
	for identity, revision := range state.Revisions {
		if identity == "" || revision < 0 {
			return errors.New("invalid revision state")
		}
	}
	if state.Sequence < 0 {
		return errors.New("sequence must be non-negative")
	}
	return nil
}

func validateEnrollment(bundle EnrollmentBundle) error {
	if bundle.Version != clientStateVersion {
		return fmt.Errorf("unsupported enrollment version %d", bundle.Version)
	}
	if strings.TrimSpace(bundle.ActiveKeyID) == "" {
		return errors.New("active key id is required")
	}
	if len(bundle.Keys) == 0 {
		return errors.New("enrollment keyring is empty")
	}
	for keyID, encoded := range bundle.Keys {
		if strings.TrimSpace(keyID) == "" {
			return errors.New("enrollment contains an empty key id")
		}
		key, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(key) != clientKeyLength {
			return fmt.Errorf("invalid enrollment key %q", keyID)
		}
	}
	if _, ok := bundle.Keys[bundle.ActiveKeyID]; !ok {
		return errors.New("active encryption key is missing")
	}
	if bundle.StagedKeyID != "" &&
		(bundle.StagedKeyID == bundle.ActiveKeyID || bundle.Keys[bundle.StagedKeyID] == "") {
		return errors.New("staged encryption key is invalid or missing")
	}
	if bundle.RetiringKeyID != "" &&
		(bundle.RetiringKeyID == bundle.ActiveKeyID || bundle.Keys[bundle.RetiringKeyID] == "") {
		return errors.New("retiring encryption key is invalid or missing")
	}
	if bundle.StagedKeyID != "" && bundle.RetiringKeyID != "" {
		return errors.New("keyring cannot be staged and retiring simultaneously")
	}
	return nil
}

func newClientKey() (string, string, error) {
	key := make([]byte, clientKeyLength)
	if _, err := rand.Read(key); err != nil {
		return "", "", err
	}
	digest := sha256.Sum256(key)
	keyID := hex.EncodeToString(digest[:12])
	return keyID, base64.StdEncoding.EncodeToString(key), nil
}

func cloneKeys(keys map[string]string) map[string]string {
	clone := make(map[string]string, len(keys))
	for key, value := range keys {
		clone[key] = value
	}
	return clone
}

type LocalSealedPayload struct {
	KeyID      string `json:"key_id"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

func (state *ClientState) SealLocalPayload(purpose string, plaintext []byte) (LocalSealedPayload, error) {
	key, _ := base64.StdEncoding.DecodeString(state.LocalSealKey)
	if len(key) != clientKeyLength || strings.TrimSpace(purpose) == "" {
		return LocalSealedPayload{}, errors.New("local seal state or purpose is invalid")
	}
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(block)
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return LocalSealedPayload{}, err
	}
	aad := canonicalLocalAAD(purpose, state.DeviceID)
	return LocalSealedPayload{
		KeyID: "device-local-v1", Nonce: base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(aead.Seal(nil, nonce, plaintext, aad)),
	}, nil
}

func (state *ClientState) OpenLocalPayload(purpose string, sealed LocalSealedPayload) ([]byte, error) {
	if sealed.KeyID != "device-local-v1" {
		return nil, errors.New("unknown device-local seal key id")
	}
	key, _ := base64.StdEncoding.DecodeString(state.LocalSealKey)
	nonce, nonceErr := base64.StdEncoding.DecodeString(sealed.Nonce)
	ciphertext, ciphertextErr := base64.StdEncoding.DecodeString(sealed.Ciphertext)
	if len(key) != clientKeyLength || nonceErr != nil || ciphertextErr != nil {
		return nil, errors.New("invalid local sealed payload encoding")
	}
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(block)
	if len(nonce) != aead.NonceSize() {
		return nil, errors.New("invalid local sealed payload nonce")
	}
	aad := canonicalLocalAAD(purpose, state.DeviceID)
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, errors.New("local sealed payload authentication failed")
	}
	return plaintext, nil
}

func canonicalLocalAAD(purpose, deviceID string) []byte {
	var buffer bytes.Buffer
	buffer.WriteString("helium-sync-local-seal-v1\x00")
	for _, field := range []string{purpose, deviceID, "device-local-v1"} {
		_ = binary.Write(&buffer, binary.BigEndian, uint32(len(field)))
		buffer.WriteString(field)
	}
	return buffer.Bytes()
}

const enrollmentProtocol = "helium-sync-enrollment-v1"

type JoinRequest struct {
	Protocol           string `json:"protocol"`
	DeviceID           string `json:"device_id"`
	RecipientPublicKey string `json:"recipient_public_key"`
	SeedSigningPublic  string `json:"seed_signing_public"`
}

type pendingJoin struct {
	Version             int    `json:"version"`
	DeviceID            string `json:"device_id"`
	RecipientPrivateKey string `json:"recipient_private_key"`
	RecipientPublicKey  string `json:"recipient_public_key"`
	SeedSigningPublic   string `json:"seed_signing_public"`
}

type WrappedEnrollment struct {
	Protocol           string `json:"protocol"`
	DeviceID           string `json:"device_id"`
	RecipientPublicKey string `json:"recipient_public_key"`
	EphemeralPublicKey string `json:"ephemeral_public_key"`
	SeedSigningPublic  string `json:"seed_signing_public"`
	Nonce              string `json:"nonce"`
	Ciphertext         string `json:"ciphertext"`
	Signature          string `json:"signature"`
}

// SeedSigningPublicKey is the small trust anchor that must be conveyed to a
// joining device through an authenticated channel before lm relays enrollment.
func (state *ClientState) SeedSigningPublicKey() string {
	return state.SeedSigningPublic
}

// CreateJoinRequest runs on the joining device. The private X25519 key remains
// only in pendingPath; lm may relay the returned public request.
func CreateJoinRequest(pendingPath, deviceID, trustedSeedSigningPublic string) (JoinRequest, error) {
	if !validDeviceID.MatchString(deviceID) || deviceID == "d" {
		return JoinRequest{}, errors.New("join device id is invalid or reserved")
	}
	trusted, err := base64.StdEncoding.DecodeString(trustedSeedSigningPublic)
	if err != nil || len(trusted) != ed25519.PublicKeySize {
		return JoinRequest{}, errors.New("trusted seed signing public key is invalid")
	}
	if _, err := os.Stat(pendingPath); err == nil {
		return JoinRequest{}, fmt.Errorf("pending enrollment already exists: %s", pendingPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return JoinRequest{}, err
	}
	privateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return JoinRequest{}, err
	}
	request := JoinRequest{
		Protocol: enrollmentProtocol, DeviceID: deviceID,
		RecipientPublicKey: base64.StdEncoding.EncodeToString(privateKey.PublicKey().Bytes()),
		SeedSigningPublic:  trustedSeedSigningPublic,
	}
	pending := pendingJoin{
		Version: clientStateVersion, DeviceID: deviceID,
		RecipientPrivateKey: base64.StdEncoding.EncodeToString(privateKey.Bytes()),
		RecipientPublicKey:  request.RecipientPublicKey,
		SeedSigningPublic:   trustedSeedSigningPublic,
	}
	raw, err := json.MarshalIndent(pending, "", "  ")
	if err != nil {
		return JoinRequest{}, err
	}
	if err := writeAtomic(pendingPath, append(raw, '\n'), 0600); err != nil {
		return JoinRequest{}, err
	}
	return request, nil
}

// WrapEnrollment runs only on d. The returned object contains ciphertext and a
// d signature, so an untrusted lm relay cannot read, retarget, or alter it.
func (state *ClientState) WrapEnrollment(request JoinRequest) (WrappedEnrollment, error) {
	if state.Role != RoleSeed || state.DeviceID != "d" {
		return WrappedEnrollment{}, errors.New("only d may wrap enrollment")
	}
	if request.Protocol != enrollmentProtocol || !validDeviceID.MatchString(request.DeviceID) || request.DeviceID == "d" {
		return WrappedEnrollment{}, errors.New("invalid join request")
	}
	if request.SeedSigningPublic != state.SeedSigningPublic {
		return WrappedEnrollment{}, errors.New("join request trusts a different seed")
	}
	recipientRaw, err := base64.StdEncoding.DecodeString(request.RecipientPublicKey)
	if err != nil {
		return WrappedEnrollment{}, errors.New("invalid recipient public key")
	}
	recipient, err := ecdh.X25519().NewPublicKey(recipientRaw)
	if err != nil {
		return WrappedEnrollment{}, errors.New("invalid recipient public key")
	}
	ephemeral, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return WrappedEnrollment{}, err
	}
	shared, err := ephemeral.ECDH(recipient)
	if err != nil {
		return WrappedEnrollment{}, err
	}
	bundle, err := state.EnrollmentBundle()
	if err != nil {
		return WrappedEnrollment{}, err
	}
	plaintext, err := json.Marshal(bundle)
	if err != nil {
		return WrappedEnrollment{}, err
	}
	wrapped := WrappedEnrollment{
		Protocol: enrollmentProtocol, DeviceID: request.DeviceID,
		RecipientPublicKey: request.RecipientPublicKey,
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(ephemeral.PublicKey().Bytes()),
		SeedSigningPublic:  state.SeedSigningPublic,
	}
	aad, err := canonicalEnrollmentAAD(wrapped)
	if err != nil {
		return WrappedEnrollment{}, err
	}
	kek := enrollmentKEK(shared, aad)
	block, _ := aes.NewCipher(kek)
	aead, _ := cipher.NewGCM(block)
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return WrappedEnrollment{}, err
	}
	ciphertext := aead.Seal(nil, nonce, plaintext, aad)
	wrapped.Nonce = base64.StdEncoding.EncodeToString(nonce)
	wrapped.Ciphertext = base64.StdEncoding.EncodeToString(ciphertext)
	privateSigning, err := base64.StdEncoding.DecodeString(state.SeedSigningPrivate)
	if err != nil {
		return WrappedEnrollment{}, err
	}
	signed := append(append(append([]byte{}, aad...), nonce...), ciphertext...)
	wrapped.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(privateSigning, signed))
	return wrapped, nil
}

// CompleteJoinState runs on the joining device and refuses any bundle missing
// a key epoch observed in the server's current live/tombstone record inventory.
func CompleteJoinState(statePath, pendingPath string, wrapped WrappedEnrollment, requiredKeyIDs []string) (*ClientState, error) {
	bundle, pending, err := unwrapEnrollment(pendingPath, wrapped)
	if err != nil {
		return nil, err
	}
	for _, keyID := range requiredKeyIDs {
		if _, ok := bundle.Keys[keyID]; !ok {
			return nil, fmt.Errorf("enrollment is missing required key id %q", keyID)
		}
	}
	return createJoinState(statePath, pending.DeviceID, pending.SeedSigningPublic, bundle)
}

// InstallKeyUpdate unwraps a d-signed keyring update on an existing join device.
// The old keys remain until a later verified latest inventory no longer needs them.
func (state *ClientState) InstallKeyUpdate(pendingPath string, wrapped WrappedEnrollment, requiredKeyIDs []string) error {
	if state.Role != RoleJoin || state.DeviceID != wrapped.DeviceID {
		return errors.New("key update is not for this join device")
	}
	bundle, pending, err := unwrapEnrollment(pendingPath, wrapped)
	if err != nil {
		return err
	}
	if pending.DeviceID != state.DeviceID || pending.SeedSigningPublic != state.SeedSigningPublic {
		return errors.New("key update is bound to different client state")
	}
	for _, keyID := range requiredKeyIDs {
		if _, ok := bundle.Keys[keyID]; !ok {
			return fmt.Errorf("key update is missing required key id %q", keyID)
		}
	}
	for keyID, key := range bundle.Keys {
		state.Keys[keyID] = key
	}
	state.ActiveKeyID = bundle.ActiveKeyID
	state.StagedKeyID = bundle.StagedKeyID
	state.RetiringKeyID = bundle.RetiringKeyID
	return state.Save()
}

// DecryptRecoveryExport unwraps an enrollment into memory without creating a
// sync state. Recovery artifacts are therefore encrypted and remain separate
// from the server's opaque record journal.
func DecryptRecoveryExport(pendingPath string, wrapped WrappedEnrollment, requiredKeyIDs []string) (EnrollmentBundle, error) {
	bundle, _, err := unwrapEnrollment(pendingPath, wrapped)
	if err != nil {
		return EnrollmentBundle{}, err
	}
	for _, keyID := range requiredKeyIDs {
		if _, ok := bundle.Keys[keyID]; !ok {
			return EnrollmentBundle{}, fmt.Errorf("recovery export is missing required key id %q", keyID)
		}
	}
	return bundle, nil
}

func unwrapEnrollment(pendingPath string, wrapped WrappedEnrollment) (EnrollmentBundle, pendingJoin, error) {
	raw, err := os.ReadFile(pendingPath)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, fmt.Errorf("read pending enrollment: %w", err)
	}
	var pending pendingJoin
	if err := strictDecode(raw, &pending); err != nil {
		return EnrollmentBundle{}, pendingJoin{}, fmt.Errorf("decode pending enrollment: %w", err)
	}
	if pending.Version != clientStateVersion || wrapped.Protocol != enrollmentProtocol ||
		wrapped.DeviceID != pending.DeviceID || wrapped.RecipientPublicKey != pending.RecipientPublicKey ||
		wrapped.SeedSigningPublic != pending.SeedSigningPublic {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("enrollment is not bound to this device and request")
	}
	aad, err := canonicalEnrollmentAAD(wrapped)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, err
	}
	nonce, err := base64.StdEncoding.DecodeString(wrapped.Nonce)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid enrollment nonce")
	}
	ciphertext, err := base64.StdEncoding.DecodeString(wrapped.Ciphertext)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid enrollment ciphertext")
	}
	signature, err := base64.StdEncoding.DecodeString(wrapped.Signature)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid enrollment signature")
	}
	seedPublic, _ := base64.StdEncoding.DecodeString(pending.SeedSigningPublic)
	signed := append(append(append([]byte{}, aad...), nonce...), ciphertext...)
	if !ed25519.Verify(seedPublic, signed, signature) {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("enrollment signature verification failed")
	}
	privateRaw, err := base64.StdEncoding.DecodeString(pending.RecipientPrivateKey)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid pending private key")
	}
	privateKey, err := ecdh.X25519().NewPrivateKey(privateRaw)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid pending private key")
	}
	ephemeralRaw, err := base64.StdEncoding.DecodeString(wrapped.EphemeralPublicKey)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid ephemeral public key")
	}
	ephemeral, err := ecdh.X25519().NewPublicKey(ephemeralRaw)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid ephemeral public key")
	}
	shared, err := privateKey.ECDH(ephemeral)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, err
	}
	block, _ := aes.NewCipher(enrollmentKEK(shared, aad))
	aead, _ := cipher.NewGCM(block)
	if len(nonce) != aead.NonceSize() {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid enrollment nonce length")
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("enrollment authentication failed")
	}
	var bundle EnrollmentBundle
	if err := strictDecode(plaintext, &bundle); err != nil {
		return EnrollmentBundle{}, pendingJoin{}, errors.New("invalid enrollment plaintext")
	}
	if err := validateEnrollment(bundle); err != nil {
		return EnrollmentBundle{}, pendingJoin{}, err
	}
	return bundle, pending, nil
}

func canonicalEnrollmentAAD(wrapped WrappedEnrollment) ([]byte, error) {
	var buffer bytes.Buffer
	buffer.WriteString(enrollmentProtocol + "\x00")
	for _, value := range []string{
		wrapped.DeviceID, wrapped.RecipientPublicKey, wrapped.EphemeralPublicKey,
		wrapped.SeedSigningPublic,
	} {
		if uint64(len(value)) > uint64(^uint32(0)) {
			return nil, errors.New("enrollment field is too large")
		}
		_ = binary.Write(&buffer, binary.BigEndian, uint32(len(value)))
		buffer.WriteString(value)
	}
	return buffer.Bytes(), nil
}

// enrollmentKEK is RFC 5869 HKDF-SHA256 (empty salt, one 32-byte block).
func enrollmentKEK(shared, aad []byte) []byte {
	zeroSalt := make([]byte, sha256.Size)
	extract := hmac.New(sha256.New, zeroSalt)
	extract.Write(shared)
	prk := extract.Sum(nil)
	expand := hmac.New(sha256.New, prk)
	expand.Write([]byte("helium-sync-enrollment-kek-v1"))
	expand.Write(aad)
	expand.Write([]byte{1})
	return expand.Sum(nil)
}
