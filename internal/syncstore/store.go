package syncstore

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	configFile  = "config.json"
	recordsFile = "records.jsonl"
)

type Store struct {
	mu          sync.Mutex
	dataDir     string
	recordsPath string
	aead        anyAEAD
	records     []StoredRecord
	nextSeq     int64
}

type anyAEAD interface {
	NonceSize() int
	Overhead() int
	Seal(dst, nonce, plaintext, additionalData []byte) []byte
	Open(dst, nonce, ciphertext, additionalData []byte) ([]byte, error)
}

func OpenStore(dataDir string, passphrase string) (*Store, error) {
	if strings.TrimSpace(dataDir) == "" {
		return nil, errors.New("data dir is required")
	}
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	config, err := loadOrCreateConfig(filepath.Join(dataDir, configFile))
	if err != nil {
		return nil, err
	}
	aead, err := newAEAD(config, passphrase)
	if err != nil {
		return nil, err
	}
	store := &Store{
		dataDir:     dataDir,
		recordsPath: filepath.Join(dataDir, recordsFile),
		aead:        aead,
		nextSeq:     1,
	}
	if err := store.loadRecords(); err != nil {
		return nil, err
	}
	return store, nil
}

func loadOrCreateConfig(path string) (Config, error) {
	raw, err := os.ReadFile(path)
	if err == nil {
		var config Config
		if err := json.Unmarshal(raw, &config); err != nil {
			return Config{}, fmt.Errorf("read config: %w", err)
		}
		return config, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	config, err := newConfig()
	if err != nil {
		return Config{}, err
	}
	raw, err = json.MarshalIndent(config, "", "  ")
	if err != nil {
		return Config{}, err
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(path, raw, 0600); err != nil {
		return Config{}, fmt.Errorf("write config: %w", err)
	}
	return config, nil
}

func (store *Store) loadRecords() error {
	file, err := os.OpenFile(store.recordsPath, os.O_RDONLY|os.O_CREATE, 0600)
	if err != nil {
		return fmt.Errorf("open records: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			continue
		}
		var record StoredRecord
		if err := json.Unmarshal([]byte(text), &record); err != nil {
			return fmt.Errorf("parse records line %d: %w", line, err)
		}
		if err := validateStored(record); err != nil {
			return fmt.Errorf("validate records line %d: %w", line, err)
		}
		store.records = append(store.records, record)
		if record.Seq >= store.nextSeq {
			store.nextSeq = record.Seq + 1
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan records: %w", err)
	}
	return nil
}

func validateStored(record StoredRecord) error {
	if record.Seq <= 0 {
		return errors.New("seq must be positive")
	}
	if _, ok := allKinds[record.Kind]; !ok {
		return fmt.Errorf("unknown record kind %q", record.Kind)
	}
	if strings.TrimSpace(record.Key) == "" {
		return errors.New("key is required")
	}
	if record.Version <= 0 {
		return errors.New("version must be positive")
	}
	if record.UpdatedAt.IsZero() {
		return errors.New("updated_at is required")
	}
	if record.Nonce == "" || record.Ciphertext == "" {
		return errors.New("encrypted payload is required")
	}
	return nil
}

func (store *Store) Put(records []PlainRecord, defaultDevice string) (PushResponse, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	if len(records) == 0 {
		return PushResponse{NextSeq: store.nextSeq}, nil
	}
	file, err := os.OpenFile(store.recordsPath, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0600)
	if err != nil {
		return PushResponse{}, fmt.Errorf("open records for append: %w", err)
	}
	defer file.Close()

	now := time.Now().UTC()
	accepted := 0
	for _, plain := range records {
		if plain.Deleted && len(plain.Payload) == 0 {
			plain.Payload = json.RawMessage(emptyJSONObject)
		}
		if err := plain.validate(); err != nil {
			return PushResponse{}, err
		}
		if plain.Version <= 0 {
			plain.Version = now.UnixNano()
		}
		if plain.UpdatedAt.IsZero() {
			plain.UpdatedAt = now
		}
		if strings.TrimSpace(plain.OriginDevice) == "" {
			plain.OriginDevice = defaultDevice
		}
		stored := StoredRecord{
			Seq:          store.nextSeq,
			Kind:         plain.Kind,
			Key:          plain.Key,
			Version:      plain.Version,
			UpdatedAt:    plain.UpdatedAt.UTC(),
			Deleted:      plain.Deleted,
			OriginDevice: plain.OriginDevice,
		}
		stored, err := encryptRecord(store.aead, stored, plain.Payload)
		if err != nil {
			return PushResponse{}, err
		}
		raw, err := json.Marshal(stored)
		if err != nil {
			return PushResponse{}, err
		}
		if _, err := file.Write(append(raw, '\n')); err != nil {
			return PushResponse{}, fmt.Errorf("append record: %w", err)
		}
		store.records = append(store.records, stored)
		store.nextSeq++
		accepted++
	}
	if err := file.Sync(); err != nil {
		return PushResponse{}, fmt.Errorf("sync records: %w", err)
	}
	return PushResponse{Accepted: accepted, NextSeq: store.nextSeq}, nil
}

func (store *Store) Pull(since int64, kinds map[Kind]struct{}) (PullResponse, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	var out []RecordEnvelope
	for _, record := range store.records {
		if record.Seq <= since || !record.matches(kinds) {
			continue
		}
		envelope, err := store.decryptEnvelope(record)
		if err != nil {
			return PullResponse{}, err
		}
		out = append(out, envelope)
	}
	return PullResponse{Records: out, NextSeq: store.nextSeq}, nil
}

func (store *Store) Latest(kinds map[Kind]struct{}, includeDeleted bool) (PullResponse, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	latest := make(map[string]StoredRecord)
	for _, record := range store.records {
		if !record.matches(kinds) {
			continue
		}
		mapKey := string(record.Kind) + "\x00" + record.Key
		current, ok := latest[mapKey]
		if !ok || record.Version > current.Version || (record.Version == current.Version && record.Seq > current.Seq) {
			latest[mapKey] = record
		}
	}
	var out []RecordEnvelope
	for _, record := range store.records {
		mapKey := string(record.Kind) + "\x00" + record.Key
		if latestRecord, ok := latest[mapKey]; !ok || latestRecord.Seq != record.Seq {
			continue
		}
		if record.Deleted && !includeDeleted {
			continue
		}
		envelope, err := store.decryptEnvelope(record)
		if err != nil {
			return PullResponse{}, err
		}
		out = append(out, envelope)
	}
	return PullResponse{Records: out, NextSeq: store.nextSeq}, nil
}

func (store *Store) decryptEnvelope(record StoredRecord) (RecordEnvelope, error) {
	payload, err := decryptRecord(store.aead, record)
	if err != nil {
		return RecordEnvelope{}, err
	}
	if !json.Valid(payload) {
		return RecordEnvelope{}, fmt.Errorf("decrypted seq %d is not valid JSON", record.Seq)
	}
	return RecordEnvelope{
		Seq:          record.Seq,
		Kind:         record.Kind,
		Key:          record.Key,
		Version:      record.Version,
		UpdatedAt:    record.UpdatedAt,
		Deleted:      record.Deleted,
		OriginDevice: record.OriginDevice,
		Payload:      json.RawMessage(payload),
	}, nil
}
