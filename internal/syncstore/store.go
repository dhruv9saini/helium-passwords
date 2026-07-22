package syncstore

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const recordsFile = "records.jsonl"

const maxOpaqueMutationBytes = 1024 * 1024

type Store struct {
	mu           sync.Mutex
	dataDir      string
	recordsPath  string
	snapshotDir  string
	records      []OpaqueRecord
	nextSeq      Counter
	seqExhausted bool
}

func OpenStore(dataDir string) (*Store, error) {
	if strings.TrimSpace(dataDir) == "" {
		return nil, errors.New("data dir is required")
	}
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	store := &Store{
		dataDir: dataDir, recordsPath: filepath.Join(dataDir, recordsFile),
		snapshotDir: filepath.Join(dataDir, "snapshots"), nextSeq: 1,
	}
	if err := store.loadRecords(); err != nil {
		if recoveryErr := store.recoverJournal(err); recoveryErr != nil {
			return nil, recoveryErr
		}
		if err := store.loadRecords(); err != nil {
			return nil, fmt.Errorf("load recovered journal: %w", err)
		}
	}
	if err := store.createSnapshot(); err != nil {
		return nil, fmt.Errorf("checkpoint journal: %w", err)
	}
	return store, nil
}

func (store *Store) loadRecords() error {
	file, err := os.OpenFile(store.recordsPath, os.O_RDONLY|os.O_CREATE, 0600)
	if err != nil {
		return fmt.Errorf("open records: %w", err)
	}
	defer file.Close()

	store.records = nil
	store.nextSeq = 1
	store.seqExhausted = false
	revisions := make(map[string]Counter)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			continue
		}
		var record OpaqueRecord
		if err := strictDecode([]byte(text), &record); err != nil {
			return fmt.Errorf("parse records line %d: %w", line, err)
		}
		if err := record.validate(); err != nil {
			return fmt.Errorf("validate records line %d: %w", line, err)
		}
		if store.seqExhausted {
			return fmt.Errorf("validate records line %d: sequence space exhausted", line)
		}
		if record.Seq != store.nextSeq {
			return fmt.Errorf("validate records line %d: wanted seq %d, got %d", line, store.nextSeq, record.Seq)
		}
		identity := recordIdentity(record.Kind, record.Key)
		if record.Revision != revisions[identity]+1 {
			return fmt.Errorf("validate records line %d: non-contiguous revision for %s/%s", line, record.Kind, record.Key)
		}
		revisions[identity] = record.Revision
		store.records = append(store.records, record)
		if record.Seq == Counter(math.MaxInt64) {
			store.seqExhausted = true
		} else {
			store.nextSeq++
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan records: %w", err)
	}
	return nil
}

// Put applies a batch atomically after checking every expected revision. The
// authenticated server principal supplies deviceID; it is never read from the
// request body.
func (store *Store) Put(deviceID string, acceptedKeyIDs map[string]struct{}, mutations []OpaqueMutation) (PushResponse, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	if strings.TrimSpace(deviceID) == "" {
		return PushResponse{}, errors.New("authenticated device id is required")
	}
	if len(mutations) == 0 {
		return PushResponse{Records: []OpaqueRecord{}, NextSeq: store.cursorLocked()}, nil
	}
	if !hasSequenceCapacity(store.nextSeq, store.seqExhausted, len(mutations)) {
		return PushResponse{}, errors.New("sequence space exhausted")
	}
	latest := make(map[string]Counter)
	for _, record := range store.records {
		latest[recordIdentity(record.Kind, record.Key)] = record.Revision
	}
	seen := make(map[string]struct{}, len(mutations))
	for _, mutation := range mutations {
		if err := mutation.validate(); err != nil {
			return PushResponse{}, err
		}
		raw, err := json.Marshal(mutation)
		if err != nil {
			return PushResponse{}, err
		}
		if len(raw) > maxOpaqueMutationBytes {
			return PushResponse{}, fmt.Errorf("opaque mutation exceeds %d-byte limit", maxOpaqueMutationBytes)
		}
		if _, accepted := acceptedKeyIDs[mutation.KeyID]; !accepted {
			return PushResponse{}, fmt.Errorf("key_id %q is not write-active", mutation.KeyID)
		}
		identity := recordIdentity(mutation.Kind, mutation.Key)
		if _, duplicate := seen[identity]; duplicate {
			return PushResponse{}, fmt.Errorf("duplicate mutation for %s/%s", mutation.Kind, mutation.Key)
		}
		seen[identity] = struct{}{}
		current := latest[identity]
		if mutation.ExpectedRevision != current {
			return PushResponse{}, &ConflictError{
				Kind: mutation.Kind, Key: mutation.Key,
				Expected: mutation.ExpectedRevision, CurrentRevision: current,
			}
		}
		if current == Counter(math.MaxInt64) {
			return PushResponse{}, errors.New("revision space exhausted")
		}
	}

	pending := make([]OpaqueRecord, 0, len(mutations))
	var encoded []byte
	for _, mutation := range mutations {
		record := OpaqueRecord{
			Seq: store.nextSeq + Counter(len(pending)), Kind: mutation.Kind,
			Key: mutation.Key, Revision: mutation.ExpectedRevision + 1,
			Deleted: mutation.Deleted, DeviceID: deviceID, KeyID: mutation.KeyID,
			Nonce: mutation.Nonce, Ciphertext: mutation.Ciphertext,
		}
		raw, err := json.Marshal(record)
		if err != nil {
			return PushResponse{}, err
		}
		encoded = append(encoded, raw...)
		encoded = append(encoded, '\n')
		pending = append(pending, record)
	}
	committed, err := store.replaceJournal(encoded)
	if !committed {
		return PushResponse{}, err
	}
	store.records = append(store.records, pending...)
	lastSeq := pending[len(pending)-1].Seq
	if lastSeq == Counter(math.MaxInt64) {
		store.nextSeq = lastSeq
		store.seqExhausted = true
	} else {
		store.nextSeq = lastSeq + 1
	}
	if err != nil {
		return PushResponse{}, err
	}
	if err := store.createSnapshot(); err != nil {
		return PushResponse{}, fmt.Errorf("checkpoint records: %w", err)
	}
	return PushResponse{Records: pending, NextSeq: store.cursorLocked()}, nil
}

// replaceJournal installs the old journal plus one complete batch through a
// same-directory temporary file. A short write, ENOSPC, failed fsync, or failed
// close before rename leaves the old journal byte-for-byte intact. Once rename
// succeeds the batch is committed even if the subsequent directory fsync
// reports an error, so the caller can keep its in-memory sequence aligned with
// the visible journal and fail closed without ever reusing those counters.
func (store *Store) replaceJournal(encoded []byte) (bool, error) {
	current, err := os.Open(store.recordsPath)
	if err != nil {
		return false, fmt.Errorf("open current records: %w", err)
	}
	defer current.Close()

	temp, err := os.CreateTemp(store.dataDir, ".records-committing-")
	if err != nil {
		return false, fmt.Errorf("create records transaction: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0600); err != nil {
		temp.Close()
		return false, fmt.Errorf("secure records transaction: %w", err)
	}
	if _, err := io.Copy(temp, current); err != nil {
		temp.Close()
		return false, fmt.Errorf("copy current records: %w", err)
	}
	if written, err := temp.Write(encoded); err != nil {
		temp.Close()
		return false, fmt.Errorf("append records transaction: %w", err)
	} else if written != len(encoded) {
		temp.Close()
		return false, fmt.Errorf("append records transaction: %w", io.ErrShortWrite)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return false, fmt.Errorf("sync records transaction: %w", err)
	}
	if err := temp.Close(); err != nil {
		return false, fmt.Errorf("close records transaction: %w", err)
	}
	if err := os.Rename(tempPath, store.recordsPath); err != nil {
		return false, fmt.Errorf("commit records transaction: %w", err)
	}
	if err := syncDirectory(store.dataDir); err != nil {
		return true, fmt.Errorf("sync committed records directory: %w", err)
	}
	return true, nil
}

func (store *Store) Cursor() Counter {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.cursorLocked()
}

func (store *Store) cursorLocked() Counter {
	if store.seqExhausted {
		return store.nextSeq
	}
	return store.nextSeq - 1
}

func hasSequenceCapacity(next Counter, exhausted bool, count int) bool {
	if exhausted || next <= 0 || count <= 0 {
		return false
	}
	return int64(count-1) <= math.MaxInt64-int64(next)
}

func recordIdentity(kind Kind, key string) string {
	return string(kind) + "\x00" + key
}
