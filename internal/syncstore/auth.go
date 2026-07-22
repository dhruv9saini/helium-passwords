package syncstore

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

const deviceRegistryVersion = 1

type DeviceRole string
type DeviceScope string
type EnrollmentPhase string

const (
	RoleSeed     DeviceRole      = "seed"
	RoleJoin     DeviceRole      = "join"
	PhasePending EnrollmentPhase = "pending"
	PhaseActive  EnrollmentPhase = "active"

	ScopePull   DeviceScope = "pull"
	ScopePush   DeviceScope = "push"
	ScopeRotate DeviceScope = "rotate"
)

type deviceEntry struct {
	ID                 string          `json:"id"`
	Role               DeviceRole      `json:"role"`
	Phase              EnrollmentPhase `json:"phase"`
	TokenHashes        []string        `json:"token_sha256"`
	ConfirmedTokenHash string          `json:"confirmed_token_sha256"`
	Scopes             []DeviceScope   `json:"scopes"`
	Revoked            bool            `json:"revoked"`
}

type registryDocument struct {
	Version        int               `json:"version"`
	ActiveKeyID    string            `json:"active_key_id"`
	StagedKeyID    string            `json:"staged_key_id"`
	RetiringKeyID  string            `json:"retiring_key_id"`
	KeyInstallAcks map[string]string `json:"key_install_acks"`
	RekeyAcks      map[string]string `json:"rekey_acks"`
	Devices        []deviceEntry     `json:"devices"`
}

type DevicePrincipal struct {
	ID             string
	Role           DeviceRole
	Phase          EnrollmentPhase
	Scopes         map[DeviceScope]struct{}
	CredentialHash string
}

// ServerBootstrap contains only values safe to transfer from d to lm. The
// server receives a credential hash and the public content-key identifier; it
// never receives d's token or any content key.
type ServerBootstrap struct {
	DeviceID    string `json:"device_id"`
	ActiveKeyID string `json:"active_key_id"`
	TokenSHA256 string `json:"token_sha256"`
}

type DeviceEnrollmentRequest struct {
	DeviceID    string `json:"device_id"`
	TokenSHA256 string `json:"token_sha256"`
}

func (principal DevicePrincipal) Allows(scope DeviceScope) bool {
	_, ok := principal.Scopes[scope]
	return ok
}

type DeviceRegistry struct {
	mu       sync.RWMutex
	path     string
	document registryDocument
}

var validDeviceID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// CreateDeviceRegistry creates the only seed identity. Greenfield enrollment is
// intentionally explicit: d is the sole seed and every later device is pull-only.
func CreateDeviceRegistry(path, seedToken, activeKeyID string) (*DeviceRegistry, error) {
	if err := validateToken(seedToken); err != nil {
		return nil, err
	}
	return CreateDeviceRegistryFromBootstrap(path, ServerBootstrap{
		DeviceID: "d", ActiveKeyID: activeKeyID, TokenSHA256: hashToken(seedToken),
	})
}

func CreateDeviceRegistryFromBootstrap(path string, bootstrap ServerBootstrap) (*DeviceRegistry, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("device registry path is required")
	}
	if _, err := os.Stat(path); err == nil {
		return nil, fmt.Errorf("device registry already exists: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if bootstrap.DeviceID != "d" || strings.TrimSpace(bootstrap.ActiveKeyID) == "" {
		return nil, errors.New("server bootstrap must describe seed device d and an active key")
	}
	if err := validateTokenHash(bootstrap.TokenSHA256); err != nil {
		return nil, err
	}
	registry := &DeviceRegistry{path: path, document: registryDocument{
		Version: deviceRegistryVersion, ActiveKeyID: bootstrap.ActiveKeyID,
		KeyInstallAcks: make(map[string]string), RekeyAcks: make(map[string]string),
		Devices: []deviceEntry{{
			ID: "d", Role: RoleSeed, Phase: PhaseActive,
			TokenHashes: []string{bootstrap.TokenSHA256}, ConfirmedTokenHash: bootstrap.TokenSHA256,
			Scopes: []DeviceScope{ScopePull, ScopePush, ScopeRotate},
		}},
	}}
	if err := registry.saveLocked(); err != nil {
		return nil, err
	}
	return registry, nil
}

func OpenDeviceRegistry(path string) (*DeviceRegistry, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read device registry: %w", err)
	}
	var document registryDocument
	if err := strictDecode(raw, &document); err != nil {
		return nil, fmt.Errorf("decode device registry: %w", err)
	}
	if err := validateRegistry(document); err != nil {
		return nil, fmt.Errorf("validate device registry: %w", err)
	}
	return &DeviceRegistry{path: path, document: document}, nil
}

func (registry *DeviceRegistry) ActiveKeyID() string {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	return registry.document.ActiveKeyID
}

func (registry *DeviceRegistry) AcceptedWriteKeyIDs() map[string]struct{} {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	accepted := map[string]struct{}{registry.document.ActiveKeyID: {}}
	if registry.document.RetiringKeyID != "" {
		accepted[registry.document.RetiringKeyID] = struct{}{}
	}
	return accepted
}

func (registry *DeviceRegistry) KeyStatus() KeyTransitionResponse {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	return KeyTransitionResponse{
		ActiveKeyID:   registry.document.ActiveKeyID,
		StagedKeyID:   registry.document.StagedKeyID,
		RetiringKeyID: registry.document.RetiringKeyID,
	}
}

func (registry *DeviceRegistry) Authenticate(token string) (DevicePrincipal, error) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	provided := hashToken(token)
	for _, device := range registry.document.Devices {
		matched := false
		for _, candidate := range device.TokenHashes {
			matched = subtle.ConstantTimeCompare([]byte(provided), []byte(candidate)) == 1 || matched
		}
		if !matched {
			continue
		}
		if device.Revoked {
			return DevicePrincipal{}, errors.New("device credential is revoked")
		}
		scopes := make(map[DeviceScope]struct{}, len(device.Scopes))
		for _, scope := range device.Scopes {
			scopes[scope] = struct{}{}
		}
		return DevicePrincipal{ID: device.ID, Role: device.Role, Phase: device.Phase, Scopes: scopes, CredentialHash: provided}, nil
	}
	return DevicePrincipal{}, errors.New("invalid device credential")
}

func (registry *DeviceRegistry) EnrollPullOnly(deviceID, token string) error {
	if err := validateToken(token); err != nil {
		return err
	}
	return registry.EnrollPullOnlyRequest(DeviceEnrollmentRequest{
		DeviceID: deviceID, TokenSHA256: hashToken(token),
	})
}

func (registry *DeviceRegistry) EnrollPullOnlyRequest(request DeviceEnrollmentRequest) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if !validDeviceID.MatchString(request.DeviceID) || request.DeviceID == "d" {
		return errors.New("join device id is invalid or reserved")
	}
	if err := validateTokenHash(request.TokenSHA256); err != nil {
		return err
	}
	for _, device := range registry.document.Devices {
		if device.ID == request.DeviceID {
			return fmt.Errorf("device %q already exists", request.DeviceID)
		}
		for _, candidate := range device.TokenHashes {
			if subtle.ConstantTimeCompare([]byte(candidate), []byte(request.TokenSHA256)) == 1 {
				return errors.New("credential is already assigned to another device")
			}
		}
	}
	registry.document.Devices = append(registry.document.Devices, deviceEntry{
		ID: request.DeviceID, Role: RoleJoin, Phase: PhasePending,
		TokenHashes: []string{request.TokenSHA256}, ConfirmedTokenHash: request.TokenSHA256,
		Scopes: []DeviceScope{ScopePull},
	})
	return registry.saveLocked()
}

func NewServerBootstrap(state *ClientState, token string) (ServerBootstrap, error) {
	if state == nil || state.DeviceID != "d" || state.Role != RoleSeed ||
		state.Phase != PhaseActive {
		return ServerBootstrap{}, errors.New("server bootstrap requires active seed state d")
	}
	if err := validateToken(token); err != nil {
		return ServerBootstrap{}, err
	}
	return ServerBootstrap{DeviceID: "d", ActiveKeyID: state.ActiveKeyID,
		TokenSHA256: hashToken(token)}, nil
}

func NewDeviceEnrollmentRequest(deviceID, token string) (DeviceEnrollmentRequest, error) {
	if !validDeviceID.MatchString(deviceID) || deviceID == "d" {
		return DeviceEnrollmentRequest{}, errors.New("join device id is invalid or reserved")
	}
	if err := validateToken(token); err != nil {
		return DeviceEnrollmentRequest{}, err
	}
	return DeviceEnrollmentRequest{DeviceID: deviceID, TokenSHA256: hashToken(token)}, nil
}

func (registry *DeviceRegistry) Promote(deviceID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.document.StagedKeyID != "" || registry.document.RetiringKeyID != "" {
		return errors.New("join promotion is blocked during content-key transition")
	}
	for index := range registry.document.Devices {
		device := &registry.document.Devices[index]
		if device.ID != deviceID {
			continue
		}
		if device.Role != RoleJoin || device.Revoked {
			return errors.New("only a live join device may complete enrollment")
		}
		if device.Phase == PhaseActive {
			return nil
		}
		if device.Phase != PhasePending {
			return errors.New("join device has an invalid enrollment phase")
		}
		device.Phase = PhaseActive
		device.Scopes = []DeviceScope{ScopePull, ScopePush}
		return registry.saveLocked()
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) Revoke(deviceID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if deviceID == "d" {
		return errors.New("the sole seed device cannot be revoked")
	}
	for index := range registry.document.Devices {
		if registry.document.Devices[index].ID == deviceID {
			registry.document.Devices[index].Revoked = true
			return registry.saveLocked()
		}
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) StageCredentialHash(deviceID, newHash string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if err := validateTokenHash(newHash); err != nil {
		return err
	}
	for _, device := range registry.document.Devices {
		for _, candidate := range device.TokenHashes {
			if subtle.ConstantTimeCompare([]byte(candidate), []byte(newHash)) == 1 {
				if device.ID == deviceID {
					return nil
				}
				return errors.New("credential is already assigned")
			}
		}
	}
	for index := range registry.document.Devices {
		if registry.document.Devices[index].ID == deviceID {
			if registry.document.Devices[index].Revoked {
				return errors.New("cannot rotate a revoked device credential")
			}
			registry.document.Devices[index].TokenHashes = append(registry.document.Devices[index].TokenHashes, newHash)
			return registry.saveLocked()
		}
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) ConfirmCredential(deviceID, credentialHash string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	for index := range registry.document.Devices {
		device := &registry.document.Devices[index]
		if device.ID != deviceID {
			continue
		}
		for _, candidate := range device.TokenHashes {
			if candidate == credentialHash {
				device.ConfirmedTokenHash = credentialHash
				return registry.saveLocked()
			}
		}
		return errors.New("credential hash is not staged for device")
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) RetireOldCredentials(deviceID, confirmedHash string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	for index := range registry.document.Devices {
		device := &registry.document.Devices[index]
		if device.ID != deviceID {
			continue
		}
		if device.ConfirmedTokenHash != confirmedHash {
			return errors.New("new credential must authenticate and confirm before retirement")
		}
		device.TokenHashes = []string{confirmedHash}
		return registry.saveLocked()
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) StageKey(expectedKeyID, newKeyID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.document.StagedKeyID == newKeyID && registry.document.ActiveKeyID == expectedKeyID {
		return nil
	}
	if expectedKeyID != registry.document.ActiveKeyID || registry.document.StagedKeyID != "" || registry.document.RetiringKeyID != "" {
		return errors.New("content-key transition is already active or base epoch changed")
	}
	if strings.TrimSpace(newKeyID) == "" || newKeyID == expectedKeyID {
		return errors.New("new key id is invalid")
	}
	registry.document.StagedKeyID = newKeyID
	registry.document.KeyInstallAcks = make(map[string]string)
	registry.document.RekeyAcks = make(map[string]string)
	return registry.saveLocked()
}

func (registry *DeviceRegistry) AcknowledgeKeyInstall(deviceID, keyID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if keyID == "" || keyID != registry.document.StagedKeyID {
		return errors.New("key is not the staged epoch")
	}
	if !registry.isActiveDeviceLocked(deviceID) {
		return errors.New("only an active device may acknowledge key installation")
	}
	registry.document.KeyInstallAcks[deviceID] = keyID
	return registry.saveLocked()
}

func (registry *DeviceRegistry) ActivateStagedKey(expectedKeyID, newKeyID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.document.ActiveKeyID == newKeyID && registry.document.RetiringKeyID == expectedKeyID {
		return nil
	}
	if registry.document.ActiveKeyID != expectedKeyID || registry.document.StagedKeyID != newKeyID || registry.document.RetiringKeyID != "" {
		return errors.New("staged content-key transition does not match")
	}
	for _, deviceID := range registry.activeDeviceIDsLocked() {
		if registry.document.KeyInstallAcks[deviceID] != newKeyID {
			return fmt.Errorf("active device %q has not installed staged key", deviceID)
		}
	}
	registry.document.ActiveKeyID = newKeyID
	registry.document.RetiringKeyID = expectedKeyID
	registry.document.StagedKeyID = ""
	registry.document.RekeyAcks = make(map[string]string)
	return registry.saveLocked()
}

func (registry *DeviceRegistry) AcknowledgeRekey(deviceID, keyID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.document.RetiringKeyID == "" || keyID != registry.document.ActiveKeyID {
		return errors.New("no matching rekey retirement is active")
	}
	if !registry.isActiveDeviceLocked(deviceID) {
		return errors.New("only an active device may acknowledge rekey")
	}
	registry.document.RekeyAcks[deviceID] = keyID
	return registry.saveLocked()
}

func (registry *DeviceRegistry) RetireKey(activeKeyID, retiringKeyID string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.document.ActiveKeyID != activeKeyID || registry.document.RetiringKeyID != retiringKeyID || retiringKeyID == "" {
		return errors.New("content-key retirement does not match")
	}
	for _, deviceID := range registry.activeDeviceIDsLocked() {
		if registry.document.RekeyAcks[deviceID] != activeKeyID {
			return fmt.Errorf("active device %q has not acknowledged rekey", deviceID)
		}
	}
	registry.document.RetiringKeyID = ""
	registry.document.KeyInstallAcks = make(map[string]string)
	registry.document.RekeyAcks = make(map[string]string)
	return registry.saveLocked()
}

func (registry *DeviceRegistry) isActiveDeviceLocked(deviceID string) bool {
	for _, device := range registry.document.Devices {
		if device.ID == deviceID {
			return !device.Revoked && device.Phase == PhaseActive
		}
	}
	return false
}

func (registry *DeviceRegistry) activeDeviceIDsLocked() []string {
	var ids []string
	for _, device := range registry.document.Devices {
		if !device.Revoked && device.Phase == PhaseActive {
			ids = append(ids, device.ID)
		}
	}
	return ids
}

func (registry *DeviceRegistry) saveLocked() error {
	raw, err := json.MarshalIndent(registry.document, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Clean(registry.path), append(raw, '\n'), 0600)
}

func validateRegistry(document registryDocument) error {
	if document.Version != deviceRegistryVersion {
		return fmt.Errorf("unsupported version %d", document.Version)
	}
	if strings.TrimSpace(document.ActiveKeyID) == "" {
		return errors.New("active_key_id is required")
	}
	seenIDs := make(map[string]struct{})
	seenHashes := make(map[string]struct{})
	seedCount := 0
	for _, device := range document.Devices {
		if !validDeviceID.MatchString(device.ID) {
			return fmt.Errorf("invalid device id %q", device.ID)
		}
		if _, exists := seenIDs[device.ID]; exists {
			return fmt.Errorf("duplicate device id %q", device.ID)
		}
		seenIDs[device.ID] = struct{}{}
		if len(device.TokenHashes) == 0 {
			return fmt.Errorf("device %q has no credentials", device.ID)
		}
		confirmed := false
		for _, tokenHash := range device.TokenHashes {
			if err := validateTokenHash(tokenHash); err != nil {
				return fmt.Errorf("invalid credential hash for %q", device.ID)
			}
			if _, exists := seenHashes[tokenHash]; exists {
				return errors.New("duplicate device credential hash")
			}
			seenHashes[tokenHash] = struct{}{}
			confirmed = confirmed || tokenHash == device.ConfirmedTokenHash
		}
		if !confirmed {
			return fmt.Errorf("device %q confirmed credential is absent", device.ID)
		}
		if device.Role == RoleSeed {
			seedCount++
			if device.ID != "d" || device.Phase != PhaseActive || !sameScopes(device.Scopes, []DeviceScope{ScopePull, ScopePush, ScopeRotate}) {
				return errors.New("seed must be d with pull, push, and rotate scopes")
			}
		} else if device.Role != RoleJoin || device.ID == "d" ||
			(device.Phase == PhasePending && !sameScopes(device.Scopes, []DeviceScope{ScopePull})) ||
			(device.Phase == PhaseActive && !sameScopes(device.Scopes, []DeviceScope{ScopePull, ScopePush})) ||
			(device.Phase != PhasePending && device.Phase != PhaseActive) {
			return fmt.Errorf("device %q has an invalid join phase or scope", device.ID)
		}
	}
	if seedCount != 1 {
		return errors.New("registry must contain exactly one d seed")
	}
	return nil
}

func sameScopes(left, right []DeviceScope) bool {
	if len(left) != len(right) {
		return false
	}
	set := make(map[DeviceScope]struct{}, len(left))
	for _, scope := range left {
		set[scope] = struct{}{}
	}
	for _, scope := range right {
		if _, ok := set[scope]; !ok {
			return false
		}
	}
	return true
}

func validateToken(token string) error {
	if len(token) < 32 {
		return errors.New("device credential must contain at least 32 characters")
	}
	return nil
}

func hashToken(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

func validateTokenHash(tokenHash string) error {
	if len(tokenHash) != sha256.Size*2 {
		return errors.New("credential hash must be SHA-256 hex")
	}
	if _, err := hex.DecodeString(tokenHash); err != nil {
		return errors.New("credential hash must be SHA-256 hex")
	}
	return nil
}

func writeAtomic(path string, raw []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".helium-sync-state-")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(mode); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(raw); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}
