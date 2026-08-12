// helium-sync-synthetic-client acknowledges fixture readback without a browser.
// It is deliberately gated by a synthetic-only marker and must never be used
// with a browser profile or personal sync state.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dhruv9saini/helium-passwords/internal/syncstore"
)

const syntheticMarker = "synthetic-only-v1"

type expectedRecord struct {
	Kind          syncstore.Kind    `json:"kind"`
	Key           string            `json:"key"`
	Revision      syncstore.Counter `json:"revision"`
	Deleted       bool              `json:"deleted"`
	DeviceID      string            `json:"device_id"`
	PayloadSHA256 string            `json:"payload_sha256"`
}

type expectedInventory struct {
	SchemaVersion int              `json:"schema_version"`
	Records       []expectedRecord `json:"records"`
}

type receiptRecord struct {
	Kind      syncstore.Kind    `json:"kind"`
	KeySHA256 string            `json:"key_sha256"`
	Revision  syncstore.Counter `json:"revision"`
	Deleted   bool              `json:"deleted"`
	DeviceID  string            `json:"device_id"`
}

type reconcileReceipt struct {
	SchemaVersion        int               `json:"schema_version"`
	DeviceID             string            `json:"device_id"`
	PhaseBefore          string            `json:"phase_before"`
	PhaseAfter           string            `json:"phase_after"`
	AcknowledgedSequence syncstore.Counter `json:"acknowledged_sequence"`
	Records              []receiptRecord   `json:"records"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "helium-sync-synthetic-client: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	flags := flag.NewFlagSet("helium-sync-synthetic-client", flag.ContinueOnError)
	markerPath := flags.String("synthetic-only-marker", "", "mode-0600 synthetic-only marker")
	baseURL := flags.String("url", "", "HTTP disposable daemon URL on the Tailnet")
	tokenPath := flags.String("token-file", "", "synthetic per-device credential")
	statePath := flags.String("state-file", "", "synthetic client state")
	expectedPath := flags.String("expected-file", "", "metadata and payload-hash inventory")
	latest := flags.Bool("latest", false, "reconcile the latest inventory instead of the incremental cursor")
	complete := flags.Bool("complete-enrollment", false, "promote a verified pending synthetic client")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *markerPath == "" || *baseURL == "" ||
		*tokenPath == "" || *statePath == "" || *expectedPath == "" {
		return errors.New("--synthetic-only-marker, --url, --token-file, --state-file, and --expected-file are required")
	}
	if err := requireSyntheticMarker(*markerPath); err != nil {
		return err
	}
	token, err := readPrivateFile(*tokenPath, 4096)
	if err != nil {
		return fmt.Errorf("read synthetic token: %w", err)
	}
	stateBefore, err := syncstore.LoadClientState(*statePath)
	if err != nil {
		return err
	}
	if *complete && stateBefore.Phase != syncstore.PhasePending {
		return errors.New("--complete-enrollment requires pending client state")
	}
	var expected expectedInventory
	if err := readStrictJSON(*expectedPath, 1024*1024, &expected); err != nil {
		return fmt.Errorf("read expected inventory: %w", err)
	}
	if err := expected.validate(); err != nil {
		return err
	}

	client, err := syncstore.NewClient(*baseURL, token, *statePath)
	if err != nil {
		return err
	}
	var response syncstore.PlainPullResponse
	if *latest {
		response, err = client.Latest(context.Background(), nil)
	} else {
		response, err = client.Pull(context.Background(), nil)
	}
	if err != nil {
		return err
	}
	records, err := verifyResponse(response, expected)
	if err != nil {
		return err
	}
	if err := client.AcknowledgeApplied(response); err != nil {
		return err
	}
	if *complete {
		if err := client.CompleteEnrollment(context.Background()); err != nil {
			return err
		}
	}
	stateAfter, err := syncstore.LoadClientState(*statePath)
	if err != nil {
		return err
	}
	receipt := reconcileReceipt{
		SchemaVersion:        2,
		DeviceID:             stateAfter.DeviceID,
		PhaseBefore:          string(stateBefore.Phase),
		PhaseAfter:           string(stateAfter.Phase),
		AcknowledgedSequence: stateAfter.Sequence,
		Records:              records,
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(receipt)
}

func requireSyntheticMarker(path string) error {
	value, err := readPrivateFile(path, 128)
	if err != nil {
		return fmt.Errorf("read synthetic-only marker: %w", err)
	}
	if value != syntheticMarker {
		return errors.New("synthetic-only marker is missing or invalid")
	}
	return nil
}

func readPrivateFile(path string, limit int64) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("path must be absolute")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 ||
		info.Size() <= 0 || info.Size() > limit {
		return "", errors.New("file must be nonempty, private, regular, and within its size limit")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return "", errors.New("file is empty")
	}
	return value, nil
}

func readStrictJSON(path string, limit int64, value any) error {
	raw, err := readPrivateFile(path, limit)
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("unexpected trailing JSON")
		}
		return err
	}
	return nil
}

func (expected expectedInventory) validate() error {
	if expected.SchemaVersion != 1 || expected.Records == nil {
		return errors.New("expected inventory must use schema_version 1 and include records")
	}
	seen := make(map[string]struct{}, len(expected.Records))
	for _, record := range expected.Records {
		identity := string(record.Kind) + "\x00" + record.Key
		if record.Kind != syncstore.KindPassword ||
			strings.TrimSpace(record.Key) == "" ||
			record.Revision <= 0 || strings.TrimSpace(record.DeviceID) == "" ||
			len(record.PayloadSHA256) != sha256.Size*2 {
			return errors.New("expected record metadata is invalid")
		}
		if _, err := hex.DecodeString(record.PayloadSHA256); err != nil {
			return errors.New("expected payload_sha256 is invalid")
		}
		if _, ok := seen[identity]; ok {
			return errors.New("expected inventory contains a duplicate record")
		}
		seen[identity] = struct{}{}
	}
	return nil
}

func verifyResponse(response syncstore.PlainPullResponse,
	expected expectedInventory) ([]receiptRecord, error) {
	if len(response.Records) != len(expected.Records) {
		return nil, fmt.Errorf("record count mismatch: got %d want %d",
			len(response.Records), len(expected.Records))
	}
	wanted := make(map[string]expectedRecord, len(expected.Records))
	for _, record := range expected.Records {
		wanted[string(record.Kind)+"\x00"+record.Key] = record
	}
	receipt := make([]receiptRecord, 0, len(response.Records))
	for _, record := range response.Records {
		identity := string(record.Kind) + "\x00" + record.Key
		expectedRecord, ok := wanted[identity]
		if !ok {
			return nil, errors.New("response contains an unexpected record")
		}
		payloadHash := sha256.Sum256(record.Payload)
		if record.Revision != expectedRecord.Revision || record.Deleted != expectedRecord.Deleted ||
			record.DeviceID != expectedRecord.DeviceID ||
			!bytes.Equal([]byte(hex.EncodeToString(payloadHash[:])), []byte(expectedRecord.PayloadSHA256)) {
			return nil, errors.New("response record metadata or payload hash does not match")
		}
		keyHash := sha256.Sum256([]byte(record.Key))
		receipt = append(receipt, receiptRecord{
			Kind: record.Kind, KeySHA256: hex.EncodeToString(keyHash[:]), Revision: record.Revision,
			Deleted: record.Deleted, DeviceID: record.DeviceID,
		})
		delete(wanted, identity)
	}
	if len(wanted) != 0 {
		return nil, errors.New("response omitted an expected record")
	}
	sort.Slice(receipt, func(left, right int) bool {
		if receipt[left].Kind != receipt[right].Kind {
			return receipt[left].Kind < receipt[right].Kind
		}
		return receipt[left].KeySHA256 < receipt[right].KeySHA256
	})
	return receipt, nil
}
