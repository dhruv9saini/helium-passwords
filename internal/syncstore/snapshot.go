package syncstore

import (
	"bufio"
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	snapshotVersion   = 1
	snapshotKeepValid = 8
	snapshotRecords   = "records.jsonl"
	snapshotManifest  = "manifest.json"
)

type snapshotMetadata struct {
	Version        int       `json:"version"`
	CreatedAt      time.Time `json:"created_at"`
	LastSeq        int64     `json:"last_seq"`
	RecordCount    int       `json:"record_count"`
	RecordsBytes   int64     `json:"records_bytes"`
	RecordsSHA256  string    `json:"records_sha256"`
	Authentication string    `json:"authentication"`
}

type validatedSnapshot struct {
	name     string
	raw      []byte
	metadata snapshotMetadata
}

func (store *Store) createSnapshot() error {
	if err := os.MkdirAll(store.snapshotDir, 0700); err != nil {
		return err
	}
	raw, err := os.ReadFile(store.recordsPath)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(raw)
	hash := hex.EncodeToString(digest[:])
	if newest, err := store.newestValidSnapshot(); err == nil &&
		newest.metadata.RecordsSHA256 == hash &&
		newest.metadata.RecordCount == len(store.records) &&
		newest.metadata.LastSeq == store.nextSeq-1 {
		return nil
	}

	created := time.Now().UTC()
	name := fmt.Sprintf("%020d-%020d", store.nextSeq-1, created.UnixNano())
	temp, err := os.MkdirTemp(store.snapshotDir, ".incoming-")
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(temp)
		}
	}()
	metadata := snapshotMetadata{
		Version:       snapshotVersion,
		CreatedAt:     created,
		LastSeq:       store.nextSeq - 1,
		RecordCount:   len(store.records),
		RecordsBytes:  int64(len(raw)),
		RecordsSHA256: hash,
	}
	metadata.Authentication, err = store.snapshotAuthentication(metadata)
	if err != nil {
		return err
	}
	if err := writeSyncedFile(filepath.Join(temp, snapshotRecords), raw, 0600); err != nil {
		return err
	}
	manifest, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	manifest = append(manifest, '\n')
	if err := writeSyncedFile(filepath.Join(temp, snapshotManifest), manifest, 0600); err != nil {
		return err
	}
	if err := syncDirectory(temp); err != nil {
		return err
	}
	if err := os.Rename(temp, filepath.Join(store.snapshotDir, name)); err != nil {
		return err
	}
	complete = true
	if err := syncDirectory(store.snapshotDir); err != nil {
		return err
	}
	return store.retainSnapshots()
}

func (store *Store) recoverJournal(journalErr error) error {
	snapshot, err := store.newestValidSnapshot()
	if err != nil {
		return fmt.Errorf("journal invalid (%v) and no valid snapshot remains: %w", journalErr, err)
	}
	quarantine := filepath.Join(store.dataDir, "quarantine")
	if err := os.MkdirAll(quarantine, 0700); err != nil {
		return err
	}
	if _, err := os.Stat(store.recordsPath); err == nil {
		generation, err := os.MkdirTemp(quarantine, "journal-")
		if err != nil {
			return err
		}
		if err := os.Rename(store.recordsPath, filepath.Join(generation, recordsFile)); err != nil {
			return fmt.Errorf("quarantine invalid journal: %w", err)
		}
		if err := syncDirectory(generation); err != nil {
			return err
		}
		if err := syncDirectory(quarantine); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	tempFile, err := os.CreateTemp(store.dataDir, ".records-recovering-")
	if err != nil {
		return err
	}
	temp := tempFile.Name()
	defer os.Remove(temp)
	if err := tempFile.Chmod(0600); err != nil {
		tempFile.Close()
		return err
	}
	if _, err := tempFile.Write(snapshot.raw); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Sync(); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Rename(temp, store.recordsPath); err != nil {
		return err
	}
	if err := syncDirectory(store.dataDir); err != nil {
		return err
	}
	return nil
}

func (store *Store) newestValidSnapshot() (validatedSnapshot, error) {
	entries, err := os.ReadDir(store.snapshotDir)
	if err != nil {
		return validatedSnapshot{}, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	for _, name := range names {
		snapshot, err := store.validateSnapshot(name)
		if err == nil {
			return snapshot, nil
		}
	}
	return validatedSnapshot{}, errors.New("no valid snapshot generation")
}

func (store *Store) validateSnapshot(name string) (validatedSnapshot, error) {
	root := filepath.Join(store.snapshotDir, name)
	manifestRaw, err := os.ReadFile(filepath.Join(root, snapshotManifest))
	if err != nil {
		return validatedSnapshot{}, err
	}
	var metadata snapshotMetadata
	if err := json.Unmarshal(manifestRaw, &metadata); err != nil {
		return validatedSnapshot{}, err
	}
	if metadata.Version != snapshotVersion || metadata.RecordCount < 0 || metadata.LastSeq < 0 {
		return validatedSnapshot{}, errors.New("invalid snapshot metadata")
	}
	provided, err := hex.DecodeString(metadata.Authentication)
	if err != nil {
		return validatedSnapshot{}, errors.New("invalid snapshot authentication")
	}
	expected, err := store.snapshotAuthentication(metadata)
	if err != nil {
		return validatedSnapshot{}, err
	}
	expectedBytes, _ := hex.DecodeString(expected)
	if !hmac.Equal(provided, expectedBytes) {
		return validatedSnapshot{}, errors.New("snapshot authentication failed")
	}
	raw, err := os.ReadFile(filepath.Join(root, snapshotRecords))
	if err != nil {
		return validatedSnapshot{}, err
	}
	if int64(len(raw)) != metadata.RecordsBytes {
		return validatedSnapshot{}, errors.New("snapshot size mismatch")
	}
	digest := sha256.Sum256(raw)
	if hex.EncodeToString(digest[:]) != metadata.RecordsSHA256 {
		return validatedSnapshot{}, errors.New("snapshot hash mismatch")
	}
	count, last, err := store.validateJournalBytes(raw)
	if err != nil {
		return validatedSnapshot{}, err
	}
	if count != metadata.RecordCount || last != metadata.LastSeq {
		return validatedSnapshot{}, errors.New("snapshot sequence inventory mismatch")
	}
	return validatedSnapshot{name: name, raw: raw, metadata: metadata}, nil
}

func (store *Store) snapshotAuthentication(metadata snapshotMetadata) (string, error) {
	metadata.Authentication = ""
	raw, err := json.Marshal(metadata)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, store.snapshotKey)
	mac.Write(raw)
	return hex.EncodeToString(mac.Sum(nil)), nil
}

func (store *Store) validateJournalBytes(raw []byte) (int, int64, error) {
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 0, 64*1024), 32*1024*1024)
	count := 0
	var last int64
	for scanner.Scan() {
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			continue
		}
		var record StoredRecord
		if err := json.Unmarshal([]byte(text), &record); err != nil {
			return 0, 0, err
		}
		if err := validateStored(record); err != nil {
			return 0, 0, err
		}
		if record.Seq != last+1 {
			return 0, 0, errors.New("non-contiguous snapshot sequence")
		}
		payload, err := decryptRecord(store.aead, record)
		if err != nil || !json.Valid(payload) {
			return 0, 0, errors.New("snapshot record authentication failed")
		}
		count++
		last = record.Seq
	}
	if err := scanner.Err(); err != nil {
		return 0, 0, err
	}
	return count, last, nil
}

func (store *Store) retainSnapshots() error {
	entries, err := os.ReadDir(store.snapshotDir)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	validSeen := 0
	for _, name := range names {
		if _, err := store.validateSnapshot(name); err != nil {
			continue
		}
		validSeen++
		if validSeen <= snapshotKeepValid {
			continue
		}
		if err := os.RemoveAll(filepath.Join(store.snapshotDir, name)); err != nil {
			return err
		}
	}
	return syncDirectory(store.snapshotDir)
}

func writeSyncedFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
