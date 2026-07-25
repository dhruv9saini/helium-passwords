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

const deviceRegistryVersion = 2

type DeviceRole string

const (
	RoleSeed DeviceRole = "seed"
	RoleJoin DeviceRole = "join"
)

type EnrollmentPhase string

const (
	PhasePending EnrollmentPhase = "pending"
	PhaseActive  EnrollmentPhase = "active"
)

type DeviceScope string

const (
	ScopePull DeviceScope = "pull"
	ScopePush DeviceScope = "push"
)

type DevicePrincipal struct {
	ID             string
	Role           DeviceRole
	Phase          EnrollmentPhase
	Scopes         map[DeviceScope]struct{}
	CredentialHash string
}

type deviceEntry struct {
	ID                 string          `json:"id"`
	Role               DeviceRole      `json:"role"`
	Phase              EnrollmentPhase `json:"phase"`
	TokenHashes        []string        `json:"token_hashes"`
	ConfirmedTokenHash string          `json:"confirmed_token_hash"`
	Scopes             []DeviceScope   `json:"scopes"`
	Revoked            bool            `json:"revoked"`
}

type registryDocument struct {
	Version int           `json:"version"`
	Devices []deviceEntry `json:"devices"`
}

// Bootstrap and enrollment requests contain only credential hashes. Plaintext
// bearer credentials remain on their owning devices.
type ServerBootstrap struct {
	DeviceID    string `json:"device_id"`
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

func CreateDeviceRegistry(path, seedToken string) (*DeviceRegistry, error) {
	if err := validateToken(seedToken); err != nil {
		return nil, err
	}
	return CreateDeviceRegistryFromBootstrap(path, ServerBootstrap{
		DeviceID: "d", TokenSHA256: hashToken(seedToken),
	})
}

func CreateDeviceRegistryFromBootstrap(path string,
	bootstrap ServerBootstrap) (*DeviceRegistry, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("device registry path is required")
	}
	if _, err := os.Stat(path); err == nil {
		return nil, fmt.Errorf("device registry already exists: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if !validDeviceID.MatchString(bootstrap.DeviceID) {
		return nil, errors.New("server bootstrap has an invalid seed device id")
	}
	if err := validateTokenHash(bootstrap.TokenSHA256); err != nil {
		return nil, err
	}
	registry := &DeviceRegistry{path: path, document: registryDocument{
		Version: deviceRegistryVersion,
		Devices: []deviceEntry{{
			ID: bootstrap.DeviceID, Role: RoleSeed, Phase: PhaseActive,
			TokenHashes:        []string{bootstrap.TokenSHA256},
			ConfirmedTokenHash: bootstrap.TokenSHA256,
			Scopes:             []DeviceScope{ScopePull, ScopePush},
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

func (registry *DeviceRegistry) PutAuthorized(
	store *Store, principal DevicePrincipal,
	mutations []Mutation) (PushResponse, error) {
	if store == nil {
		return PushResponse{}, errors.New("sync store is not configured")
	}
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	if !registry.principalAllowsLocked(principal, ScopePush) {
		return PushResponse{}, errDeviceAuthorizationChanged
	}
	return store.Put(principal.ID, mutations)
}

func (registry *DeviceRegistry) principalAllowsLocked(
	principal DevicePrincipal, scope DeviceScope) bool {
	for _, device := range registry.document.Devices {
		if device.ID != principal.ID || device.Revoked ||
			device.Phase != principal.Phase || device.Role != principal.Role {
			continue
		}
		credentialMatches := false
		for _, candidate := range device.TokenHashes {
			credentialMatches = subtle.ConstantTimeCompare(
				[]byte(candidate), []byte(principal.CredentialHash)) == 1 ||
				credentialMatches
		}
		if !credentialMatches {
			return false
		}
		for _, candidate := range device.Scopes {
			if candidate == scope {
				return true
			}
		}
		return false
	}
	return false
}

func (registry *DeviceRegistry) Authenticate(token string) (DevicePrincipal, error) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	provided := hashToken(token)
	for _, device := range registry.document.Devices {
		matched := false
		for _, candidate := range device.TokenHashes {
			matched = subtle.ConstantTimeCompare(
				[]byte(provided), []byte(candidate)) == 1 || matched
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
		return DevicePrincipal{
			ID: device.ID, Role: device.Role, Phase: device.Phase,
			Scopes: scopes, CredentialHash: provided,
		}, nil
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

func (registry *DeviceRegistry) EnrollPullOnlyRequest(
	request DeviceEnrollmentRequest) error {
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
			if subtle.ConstantTimeCompare(
				[]byte(candidate), []byte(request.TokenSHA256)) == 1 {
				return errors.New("credential is already assigned to another device")
			}
		}
	}
	registry.document.Devices = append(registry.document.Devices, deviceEntry{
		ID: request.DeviceID, Role: RoleJoin, Phase: PhasePending,
		TokenHashes:        []string{request.TokenSHA256},
		ConfirmedTokenHash: request.TokenSHA256,
		Scopes:             []DeviceScope{ScopePull},
	})
	return registry.saveLocked()
}

func NewServerBootstrap(state *ClientState, token string) (ServerBootstrap, error) {
	if state == nil || state.Role != RoleSeed ||
		state.Phase != PhaseActive {
		return ServerBootstrap{}, errors.New("server bootstrap requires an active seed state")
	}
	if err := validateToken(token); err != nil {
		return ServerBootstrap{}, err
	}
	return ServerBootstrap{
		DeviceID: state.DeviceID, TokenSHA256: hashToken(token),
	}, nil
}

func NewDeviceEnrollmentRequest(deviceID, token string) (DeviceEnrollmentRequest, error) {
	if !validDeviceID.MatchString(deviceID) || deviceID == "d" {
		return DeviceEnrollmentRequest{}, errors.New("join device id is invalid or reserved")
	}
	if err := validateToken(token); err != nil {
		return DeviceEnrollmentRequest{}, err
	}
	return DeviceEnrollmentRequest{
		DeviceID: deviceID, TokenSHA256: hashToken(token),
	}, nil
}

// PromoteAtCursor atomically changes a pending pull-only join to active only
// when its browser-verified cursor is current.
func (registry *DeviceRegistry) PromoteAtCursor(
	store *Store, deviceID string, acknowledged Counter) (Counter, error) {
	if store == nil {
		return 0, errors.New("sync store is not configured")
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	store.mu.Lock()
	defer store.mu.Unlock()
	current := store.cursorLocked()
	if acknowledged != current {
		return current, fmt.Errorf(
			"acknowledged sequence %d is not current sequence %d",
			acknowledged, current)
	}
	return current, registry.promoteLocked(deviceID)
}

func (registry *DeviceRegistry) promoteLocked(deviceID string) error {
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
	for index := range registry.document.Devices {
		if registry.document.Devices[index].ID == deviceID {
			if registry.document.Devices[index].Role == RoleSeed {
				return errors.New("the sole seed device cannot be revoked")
			}
			registry.document.Devices[index].Revoked = true
			return registry.saveLocked()
		}
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) StageCredentialHash(
	deviceID, newHash string) error {
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
			device := &registry.document.Devices[index]
			if device.Revoked {
				return errors.New("cannot rotate a revoked device credential")
			}
			device.TokenHashes = append(device.TokenHashes, newHash)
			return registry.saveLocked()
		}
	}
	return fmt.Errorf("unknown device %q", deviceID)
}

func (registry *DeviceRegistry) ConfirmCredential(
	deviceID, credentialHash string) error {
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

func (registry *DeviceRegistry) RetireOldCredentials(
	deviceID, confirmedHash string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	for index := range registry.document.Devices {
		device := &registry.document.Devices[index]
		if device.ID != deviceID {
			continue
		}
		if device.ConfirmedTokenHash != confirmedHash {
			return errors.New(
				"new credential must authenticate and confirm before retirement")
		}
		device.TokenHashes = []string{confirmedHash}
		return registry.saveLocked()
	}
	return fmt.Errorf("unknown device %q", deviceID)
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
			return fmt.Errorf(
				"device %q confirmed credential is absent", device.ID)
		}
		if device.Role == RoleSeed {
			seedCount++
			if device.Phase != PhaseActive ||
				!sameScopes(device.Scopes,
					[]DeviceScope{ScopePull, ScopePush}) {
				return errors.New("seed must be active with pull and push scopes")
			}
		} else if device.Role != RoleJoin || device.ID == "d" ||
			(device.Phase == PhasePending &&
				!sameScopes(device.Scopes, []DeviceScope{ScopePull})) ||
			(device.Phase == PhaseActive &&
				!sameScopes(device.Scopes,
					[]DeviceScope{ScopePull, ScopePush})) ||
			(device.Phase != PhasePending && device.Phase != PhaseActive) {
			return fmt.Errorf(
				"device %q has an invalid join phase or scope", device.ID)
		}
	}
	if seedCount != 1 {
		return errors.New("registry must contain exactly one seed")
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
