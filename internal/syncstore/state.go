package syncstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const clientStateVersion = 2

type ClientState struct {
	Version   int                `json:"version"`
	DeviceID  string             `json:"device_id"`
	Role      DeviceRole         `json:"role"`
	Phase     EnrollmentPhase    `json:"phase"`
	Revisions map[string]Counter `json:"revisions"`
	Sequence  Counter            `json:"sequence"`
	path      string
}

func CreateSeedState(path string) (*ClientState, error) {
	return createClientState(path, "d", RoleSeed, PhaseActive)
}

func CreateJoinState(path, deviceID string) (*ClientState, error) {
	if deviceID == "d" {
		return nil, errors.New("join device id is reserved")
	}
	return createClientState(path, deviceID, RoleJoin, PhasePending)
}

func createClientState(path, deviceID string, role DeviceRole,
	phase EnrollmentPhase) (*ClientState, error) {
	if _, err := os.Stat(path); err == nil {
		return nil, fmt.Errorf("client state already exists: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	state := &ClientState{
		Version: clientStateVersion, DeviceID: deviceID, Role: role,
		Phase: phase, Revisions: make(map[string]Counter), path: path,
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

func (state *ClientState) revision(kind Kind, key string) Counter {
	return state.Revisions[recordIdentity(kind, key)]
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
			return errors.New("only active d may have the seed role")
		}
	} else if state.Role != RoleJoin || state.DeviceID == "d" ||
		(state.Phase != PhasePending && state.Phase != PhaseActive) {
		return errors.New("non-d devices must have the join role")
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
