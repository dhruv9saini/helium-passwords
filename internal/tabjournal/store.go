package tabjournal

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	manifestFile       = "manifest.json"
	segmentsDirectory  = "segments"
	journalMarkerFile  = ".helium-tab-journal-root-v1"
	journalMarker      = "helium-tab-journal-root-v1\n"
	rootMarkerFile     = ".helium-tab-journal-disposable-root-v1"
	rootMarkerContent  = "helium-tab-journal-disposable-root-v1\n"
	restoreMarkerFile  = ".helium-tab-journal-catalog-v1"
	restoreMarker      = "helium-tab-journal-catalog-v1\n"
	restoreReceiptFile = "journal-restore.json"
	catalogFile        = "tabs.html"
)

type Store struct {
	root        string
	generations string
	quarantine  string
}

func Open(root string) (*Store, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("journal store is required")
	}
	absolute, err := filepath.Abs(root)
	if err != nil || absolute == filepath.Clean(string(os.PathSeparator)) {
		return nil, errors.New("invalid journal store")
	}
	store := &Store{
		root:        absolute,
		generations: filepath.Join(absolute, "generations"),
		quarantine:  filepath.Join(absolute, "quarantine"),
	}
	for _, directory := range []string{store.root, store.generations, store.quarantine} {
		if err := ensurePrivateDirectory(directory); err != nil {
			return nil, err
		}
	}
	return store, nil
}

func (store *Store) Capture(request CaptureRequest) (Manifest, error) {
	if !validSlug(request.Device) || !validSlug(request.Profile) {
		return Manifest{}, errors.New("device and profile must be slugs")
	}
	journalRoot, err := filepath.Abs(request.JournalRoot)
	if err != nil || requirePrivateDirectory(journalRoot) != nil {
		return Manifest{}, errors.New("invalid journal root")
	}
	marker, err := readPrivate(filepath.Join(journalRoot, journalMarkerFile), 256)
	if err != nil || string(marker) != journalMarker {
		return Manifest{}, errors.New("invalid journal root marker")
	}
	sourceFiles, err := journalInventory(journalRoot)
	if err != nil {
		return Manifest{}, err
	}
	if request.CapturedAt.IsZero() {
		request.CapturedAt = time.Now().UTC()
	} else {
		request.CapturedAt = request.CapturedAt.UTC()
	}
	generation, err := generationID(request.CapturedAt)
	if err != nil {
		return Manifest{}, err
	}
	temporary := filepath.Join(store.generations, ".tmp-"+generation)
	if err := os.Mkdir(temporary, 0700); err != nil {
		return Manifest{}, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	segments := filepath.Join(temporary, segmentsDirectory)
	if err := os.Mkdir(segments, 0700); err != nil {
		return Manifest{}, err
	}
	records := make(map[string]SegmentRecord)
	epochs := make(map[string]struct{})
	var latestEventMillis int64
	for name, source := range sourceFiles {
		destination := filepath.Join(segments, name)
		if err := onlineBackup(source, destination); err != nil {
			return Manifest{}, err
		}
		record, _, err := validateSegment(destination)
		if err != nil {
			return Manifest{}, fmt.Errorf("validate captured segment %s: %w", name, err)
		}
		if _, exists := epochs[record.Epoch]; exists {
			return Manifest{}, errors.New("duplicate journal epoch")
		}
		epochs[record.Epoch] = struct{}{}
		records[name] = record
		eventMillis, err := strconv.ParseInt(record.LastOccurredAtUnixMillis, 10, 64)
		if err != nil {
			return Manifest{}, errors.New("invalid latest journal event time")
		}
		if eventMillis > latestEventMillis {
			latestEventMillis = eventMillis
		}
	}
	capturedMillis := request.CapturedAt.UnixMilli()
	if latestEventMillis > capturedMillis+60_000 ||
		capturedMillis-latestEventMillis > 10*60_000 {
		return Manifest{}, errors.New("latest journal checkpoint is stale or future-dated")
	}
	manifest := Manifest{
		SchemaVersion: StoreSchemaVersion,
		Generation:    generation,
		Device:        request.Device,
		Profile:       request.Profile,
		CapturedAt:    request.CapturedAt,
		Protected:     request.Protected,
		Format:        "append-only-sqlite-hash-chain",
		Segments:      records,
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return Manifest{}, err
	}
	if err := writeNewSynced(filepath.Join(temporary, manifestFile),
		append(raw, '\n'), 0600); err != nil {
		return Manifest{}, err
	}
	for _, directory := range []string{segments, temporary} {
		if err := syncDirectory(directory); err != nil {
			return Manifest{}, err
		}
	}
	final := filepath.Join(store.generations, generation)
	if err := unix.Renameat2(unix.AT_FDCWD, temporary, unix.AT_FDCWD,
		final, unix.RENAME_NOREPLACE); err != nil {
		return Manifest{}, err
	}
	committed = true
	if err := syncDirectory(store.generations); err != nil {
		return Manifest{}, err
	}
	return store.Validate(generation)
}

func (store *Store) Validate(generation string) (Manifest, error) {
	if !validGeneration(generation) {
		return Manifest{}, errors.New("invalid journal generation")
	}
	directory := filepath.Join(store.generations, generation)
	if err := requirePrivateDirectory(directory); err != nil {
		return Manifest{}, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 2 ||
		entries[0].Name() != manifestFile ||
		entries[1].Name() != segmentsDirectory {
		return Manifest{}, errors.New("invalid journal generation inventory")
	}
	raw, err := readPrivate(filepath.Join(directory, manifestFile), 1024*1024)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := strictJSON(raw, &manifest); err != nil {
		return Manifest{}, err
	}
	if manifest.SchemaVersion != StoreSchemaVersion ||
		manifest.Generation != generation ||
		!validSlug(manifest.Device) || !validSlug(manifest.Profile) ||
		manifest.CapturedAt.IsZero() ||
		manifest.Format != "append-only-sqlite-hash-chain" ||
		len(manifest.Segments) == 0 || len(manifest.Segments) > 128 {
		return Manifest{}, errors.New("invalid journal manifest")
	}
	if timestamp, err := generationTime(generation); err != nil ||
		!timestamp.Equal(manifest.CapturedAt) {
		return Manifest{}, errors.New("journal generation time mismatch")
	}
	segments := filepath.Join(directory, segmentsDirectory)
	if err := requirePrivateDirectory(segments); err != nil {
		return Manifest{}, err
	}
	segmentEntries, err := os.ReadDir(segments)
	if err != nil || len(segmentEntries) != len(manifest.Segments) {
		return Manifest{}, errors.New("journal segment inventory mismatch")
	}
	epochs := make(map[string]struct{})
	for _, entry := range segmentEntries {
		if !validSegmentName(entry.Name()) || entry.IsDir() {
			return Manifest{}, errors.New("invalid journal segment name")
		}
		expected, exists := manifest.Segments[entry.Name()]
		if !exists {
			return Manifest{}, errors.New("unexpected journal segment")
		}
		actual, _, err := validateSegment(filepath.Join(segments, entry.Name()))
		if err != nil || actual != expected {
			return Manifest{}, errors.New("journal segment validation mismatch")
		}
		if _, exists := epochs[actual.Epoch]; exists {
			return Manifest{}, errors.New("duplicate journal epoch")
		}
		epochs[actual.Epoch] = struct{}{}
	}
	return manifest, nil
}

func journalInventory(root string) (map[string]string, error) {
	expectedDirectories := map[string]bool{"closed": true}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	files := make(map[string]string)
	for _, entry := range entries {
		switch {
		case entry.Name() == journalMarkerFile && !entry.IsDir():
			marker, err := readPrivate(filepath.Join(root, entry.Name()), 256)
			if err != nil || string(marker) != journalMarker {
				return nil, errors.New("invalid journal root marker")
			}
		case entry.Name() == "active.sqlite" && !entry.IsDir():
			files["active.sqlite"] = filepath.Join(root, entry.Name())
		case (entry.Name() == "active.sqlite-wal" ||
			entry.Name() == "active.sqlite-shm") && !entry.IsDir():
			// SQLite owns these live sidecars. The online backup reads their
			// committed contents through active.sqlite; copying either file
			// directly would create a non-atomic, unusable segment.
			continue
		case expectedDirectories[entry.Name()] && entry.IsDir():
			directory := filepath.Join(root, entry.Name())
			if err := requirePrivateDirectory(directory); err != nil {
				return nil, err
			}
			closed, err := os.ReadDir(directory)
			if err != nil {
				return nil, err
			}
			for _, segment := range closed {
				if !validSegmentName(segment.Name()) || segment.IsDir() {
					return nil, errors.New("unexpected closed journal entry")
				}
				files["closed-"+segment.Name()] = filepath.Join(directory, segment.Name())
			}
		default:
			return nil, errors.New("unexpected journal root entry")
		}
	}
	if len(files) == 0 || len(files) > 128 {
		return nil, errors.New("invalid journal segment count")
	}
	return files, nil
}

func validSegmentName(name string) bool {
	if name == "active.sqlite" {
		return true
	}
	if strings.HasPrefix(name, "closed-") {
		name = strings.TrimPrefix(name, "closed-")
	}
	return filepath.Base(name) == name && strings.HasSuffix(name, ".sqlite") &&
		validSlug(strings.TrimSuffix(name, ".sqlite"))
}

func (store *Store) LatestCheckpoint(generation string) (Manifest, string, SegmentRecord, Checkpoint, error) {
	manifest, err := store.Validate(generation)
	if err != nil {
		return Manifest{}, "", SegmentRecord{}, Checkpoint{}, err
	}
	type candidate struct {
		name       string
		record     SegmentRecord
		checkpoint Checkpoint
	}
	var candidates []candidate
	for name, record := range manifest.Segments {
		actual, checkpoint, err := validateSegment(filepath.Join(
			store.generations, generation, segmentsDirectory, name))
		if err != nil || actual != record {
			return Manifest{}, "", SegmentRecord{}, Checkpoint{},
				errors.New("journal segment changed after validation")
		}
		candidates = append(candidates, candidate{name, record, checkpoint})
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].record.Epoch < candidates[j].record.Epoch
	})
	selected := candidates[len(candidates)-1]
	return manifest, selected.name, selected.record, selected.checkpoint, nil
}

func (store *Store) PlanRetention() (RetentionPlan, error) {
	entries, err := os.ReadDir(store.generations)
	if err != nil {
		return RetentionPlan{}, err
	}
	type item struct {
		manifest Manifest
		valid    bool
	}
	var items []item
	for _, entry := range entries {
		if !entry.IsDir() || !validGeneration(entry.Name()) {
			continue
		}
		manifest, validationErr := store.Validate(entry.Name())
		if validationErr != nil {
			manifest.Generation = entry.Name()
			manifest.CapturedAt, _ = generationTime(entry.Name())
		}
		items = append(items, item{manifest, validationErr == nil})
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].manifest.CapturedAt.After(items[j].manifest.CapturedAt)
	})
	keep := make(map[string]struct{})
	validKept := 0
	for _, item := range items {
		if !item.valid || item.manifest.Protected || validKept < 96 {
			keep[item.manifest.Generation] = struct{}{}
			if item.valid && !item.manifest.Protected {
				validKept++
			}
		}
	}
	var plan RetentionPlan
	for _, item := range items {
		if _, ok := keep[item.manifest.Generation]; ok {
			plan.Keep = append(plan.Keep, item.manifest.Generation)
		} else {
			plan.Delete = append(plan.Delete, item.manifest.Generation)
		}
	}
	return plan, nil
}

func (store *Store) ApplyRetention(plan RetentionPlan) error {
	current, err := store.PlanRetention()
	if err != nil {
		return err
	}
	if strings.Join(current.Delete, "\n") != strings.Join(plan.Delete, "\n") {
		return errors.New("journal retention plan changed")
	}
	for _, generation := range plan.Delete {
		if _, err := store.Validate(generation); err != nil {
			return errors.New("journal retention refuses invalid generation")
		}
	}
	for _, generation := range plan.Delete {
		if err := os.RemoveAll(filepath.Join(store.generations, generation)); err != nil {
			return err
		}
	}
	return syncDirectory(store.generations)
}

func generationID(capturedAt time.Time) (string, error) {
	random := make([]byte, 8)
	if _, err := io.ReadFull(rand.Reader, random); err != nil {
		return "", err
	}
	return capturedAt.UTC().Format("20060102T150405.000000000Z") + "-" +
		hex.EncodeToString(random), nil
}

func validGeneration(value string) bool {
	_, err := generationTime(value)
	return filepath.Base(value) == value && err == nil
}

func generationTime(value string) (time.Time, error) {
	separator := strings.LastIndexByte(value, '-')
	if separator <= 0 || len(value)-separator-1 != 16 {
		return time.Time{}, errors.New("invalid generation")
	}
	if _, err := hex.DecodeString(value[separator+1:]); err != nil {
		return time.Time{}, err
	}
	return time.Parse("20060102T150405.000000000Z", value[:separator])
}

func validSlug(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for index, character := range value {
		if character >= 'a' && character <= 'z' ||
			character >= '0' && character <= '9' ||
			index > 0 && (character == '.' || character == '_' || character == '-') {
			continue
		}
		return false
	}
	return true
}

func ensurePrivateDirectory(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	if err := os.Chmod(path, 0700); err != nil {
		return err
	}
	return requirePrivateDirectory(path)
}

func requirePrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 ||
		info.Mode().Perm()&0077 != 0 {
		return errors.New("path is not a private non-symlink directory")
	}
	return nil
}

func readPrivate(path string, limit int64) ([]byte, error) {
	if err := requirePrivateRegular(path, limit); err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

func writeNewSynced(path string, raw []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(raw); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func strictJSON(raw []byte, destination any) error {
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("unexpected trailing JSON")
	}
	return nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
