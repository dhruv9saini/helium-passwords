package sessioncapsule

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
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
	manifestFile                  = "manifest.json"
	nativeDirectory               = "native"
	maxNativeFiles                = 64
	maxNativeFileBytes      int64 = 128 * 1024 * 1024
	maxNativeTotalBytes     int64 = 512 * 1024 * 1024
	rootMarkerFile                = ".helium-native-session-disposable-root-v1"
	rootMarkerContent             = "helium-native-session-disposable-root-v1\n"
	profileMarkerFile             = ".helium-native-session-capsule-v1"
	profileMarkerContent          = "helium-native-session-capsule-v1\n"
	restoreReceiptFile            = "capsule-restore.json"
	pinnedChromiumCommit          = "24b04c927b23c39cf9c5227cc8dc6f64a744c8e9"
	cleartextSessionVersion       = int32(3)
	sessionFileSignature          = uint32(0x53534e53)
	initialStateMarkerID          = byte(255)
)

type Store struct {
	root        string
	generations string
	quarantine  string
}

func Open(root string) (*Store, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("capsule store is required")
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve capsule store: %w", err)
	}
	if absolute == filepath.Clean(string(os.PathSeparator)) {
		return nil, errors.New("capsule store cannot be the filesystem root")
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
	sessionsDirectory, guardPath, err := validateCapturePaths(request)
	if err != nil {
		return Manifest{}, err
	}
	guard, err := acquireGuard(guardPath, unix.LOCK_EX|unix.LOCK_NB)
	if err != nil {
		return Manifest{}, fmt.Errorf("browser session guard is held; capture requires a stopped browser: %w", err)
	}
	defer releaseGuard(guard)

	files, records, err := readNativeSessions(sessionsDirectory)
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
	manifest := Manifest{
		SchemaVersion:  SchemaVersion,
		Generation:     generation,
		Device:         request.Device,
		Profile:        request.Profile,
		CapturedAt:     request.CapturedAt,
		Protected:      request.Protected,
		Format:         "chromium-native-sessions",
		Validation:     "stopped-guard-pinned-v150-command-parse",
		ChromiumCommit: pinnedChromiumCommit,
		Files:          records,
	}
	rawManifest, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return Manifest{}, err
	}
	rawManifest = append(rawManifest, '\n')
	temporary := filepath.Join(store.generations, ".tmp-"+generation)
	final := filepath.Join(store.generations, generation)
	if err := os.Mkdir(temporary, 0700); err != nil {
		return Manifest{}, fmt.Errorf("create capsule staging: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	native := filepath.Join(temporary, nativeDirectory)
	if err := os.Mkdir(native, 0700); err != nil {
		return Manifest{}, err
	}
	for name, raw := range files {
		if err := writeNewSynced(filepath.Join(native, name), raw, 0600); err != nil {
			return Manifest{}, err
		}
	}
	if err := writeNewSynced(filepath.Join(temporary, manifestFile), rawManifest, 0600); err != nil {
		return Manifest{}, err
	}
	for _, directory := range []string{native, temporary} {
		if err := syncDirectory(directory); err != nil {
			return Manifest{}, err
		}
	}
	if err := os.Rename(temporary, final); err != nil {
		return Manifest{}, fmt.Errorf("commit capsule generation: %w", err)
	}
	if err := syncDirectory(store.generations); err != nil {
		return Manifest{}, err
	}
	committed = true
	if _, err := store.Validate(generation); err != nil {
		return Manifest{}, fmt.Errorf("validate committed capsule: %w", err)
	}
	return manifest, nil
}

func (store *Store) Validate(generation string) (Manifest, error) {
	if !validGeneration(generation) {
		return Manifest{}, errors.New("invalid capsule generation")
	}
	directory := filepath.Join(store.generations, generation)
	if err := requirePrivateDirectory(directory); err != nil {
		return Manifest{}, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 2 || entries[0].Name() != manifestFile ||
		entries[1].Name() != nativeDirectory {
		return Manifest{}, errors.New("invalid capsule inventory")
	}
	rawManifest, err := readPrivateRegular(filepath.Join(directory, manifestFile), 1024*1024)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := strictJSON(rawManifest, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode capsule manifest: %w", err)
	}
	if manifest.SchemaVersion != SchemaVersion || manifest.Generation != generation ||
		!validSlug(manifest.Device) || !validSlug(manifest.Profile) ||
		manifest.CapturedAt.IsZero() || manifest.Format != "chromium-native-sessions" ||
		manifest.Validation != "stopped-guard-pinned-v150-command-parse" ||
		manifest.ChromiumCommit != pinnedChromiumCommit ||
		len(manifest.Files) < 2 || len(manifest.Files) > maxNativeFiles {
		return Manifest{}, errors.New("invalid capsule manifest")
	}
	if timestamp, err := generationTime(generation); err != nil || !timestamp.Equal(manifest.CapturedAt) {
		return Manifest{}, errors.New("capsule generation time mismatch")
	}
	native := filepath.Join(directory, nativeDirectory)
	if err := requirePrivateDirectory(native); err != nil {
		return Manifest{}, err
	}
	nativeEntries, err := os.ReadDir(native)
	if err != nil || len(nativeEntries) != len(manifest.Files) {
		return Manifest{}, errors.New("capsule native inventory mismatch")
	}
	hasSession := false
	hasTabs := false
	for _, entry := range nativeEntries {
		name := entry.Name()
		kind, ok := nativeFileKind(name)
		if !ok || entry.IsDir() {
			return Manifest{}, errors.New("invalid capsule native filename")
		}
		hasSession = hasSession || kind == "Session"
		hasTabs = hasTabs || kind == "Tabs"
		record, exists := manifest.Files[name]
		if !exists || record.Size <= 0 || record.Size > maxNativeFileBytes ||
			len(record.SHA256) != sha256.Size*2 ||
			record.FormatVersion != cleartextSessionVersion ||
			record.CommandCount <= 0 || record.MarkerCount <= 0 {
			return Manifest{}, errors.New("invalid capsule file record")
		}
		raw, err := readPrivateRegular(filepath.Join(native, name), maxNativeFileBytes)
		if err != nil {
			return Manifest{}, err
		}
		sum := sha256.Sum256(raw)
		if int64(len(raw)) != record.Size || hex.EncodeToString(sum[:]) != record.SHA256 {
			return Manifest{}, errors.New("capsule file checksum mismatch")
		}
		parsed, err := inspectNativeSession(raw)
		if err != nil || parsed.FormatVersion != record.FormatVersion ||
			parsed.CommandCount != record.CommandCount ||
			parsed.MarkerCount != record.MarkerCount {
			return Manifest{}, errors.New("capsule native semantic validation mismatch")
		}
	}
	if !hasSession || !hasTabs {
		return Manifest{}, errors.New("capsule requires Session and Tabs files")
	}
	return manifest, nil
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
			if capturedAt, parseErr := generationTime(entry.Name()); parseErr == nil {
				manifest.CapturedAt = capturedAt
			}
		}
		items = append(items, item{manifest: manifest, valid: validationErr == nil})
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].manifest.CapturedAt.After(items[j].manifest.CapturedAt)
	})
	keep := make(map[string]struct{})
	validKept := 0
	for _, item := range items {
		if !item.valid || item.manifest.Protected || validKept < 8 {
			keep[item.manifest.Generation] = struct{}{}
			if item.valid && !item.manifest.Protected {
				validKept++
			}
		}
	}
	var plan RetentionPlan
	for _, item := range items {
		if _, exists := keep[item.manifest.Generation]; exists {
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
		return errors.New("capsule retention plan changed")
	}
	for _, generation := range plan.Delete {
		if _, err := store.Validate(generation); err != nil {
			return errors.New("capsule retention refuses invalid generation")
		}
	}
	for _, generation := range plan.Delete {
		if err := os.RemoveAll(filepath.Join(store.generations, generation)); err != nil {
			return err
		}
	}
	return syncDirectory(store.generations)
}

func (store *Store) Restore(generation, disposableRoot, profile string) (string, error) {
	manifest, err := store.Validate(generation)
	if err != nil {
		return "", err
	}
	if !validSlug(profile) || !strings.HasPrefix(profile, "drill-native-") {
		return "", errors.New("capsule restore profile must be drill-native-*")
	}
	root, err := filepath.Abs(disposableRoot)
	if err != nil {
		return "", err
	}
	if err := requirePrivateDirectory(root); err != nil {
		return "", err
	}
	marker, err := readPrivateRegular(filepath.Join(root, rootMarkerFile), 256)
	if err != nil || string(marker) != rootMarkerContent {
		return "", errors.New("invalid native-session disposable root marker")
	}
	destination := filepath.Join(root, profile)
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("native-session restore target already exists")
	}
	temporary, err := os.MkdirTemp(root, ".native-session-restore-")
	if err != nil {
		return "", err
	}
	if err := os.Chmod(temporary, 0700); err != nil {
		return "", err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	sessions := filepath.Join(temporary, "Default", "Sessions")
	if err := os.MkdirAll(sessions, 0700); err != nil {
		return "", err
	}
	for name := range manifest.Files {
		raw, err := readPrivateRegular(
			filepath.Join(store.generations, generation, nativeDirectory, name),
			maxNativeFileBytes,
		)
		if err != nil {
			return "", err
		}
		if err := writeNewSynced(filepath.Join(sessions, name), raw, 0600); err != nil {
			return "", err
		}
	}
	if err := writeNewSynced(filepath.Join(temporary, profileMarkerFile),
		[]byte(profileMarkerContent), 0600); err != nil {
		return "", err
	}
	receipt := RestoreReceipt{
		SchemaVersion:    RestoreSchemaVersion,
		SourceGeneration: generation,
		SourceDevice:     manifest.Device,
		SourceProfile:    manifest.Profile,
		RestoredAt:       time.Now().UTC(),
		Invocation:       "explicit-chromium-restore-last-session-only",
		State:            "prepared-not-opened",
		Files:            manifest.Files,
	}
	rawReceipt, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	if err := writeNewSynced(filepath.Join(temporary, restoreReceiptFile),
		append(rawReceipt, '\n'), 0600); err != nil {
		return "", err
	}
	if err := writeNewSynced(filepath.Join(temporary, "Default", "Preferences"),
		[]byte("{}\n"), 0600); err != nil {
		return "", err
	}
	for _, directory := range []string{sessions, filepath.Join(temporary, "Default"), temporary} {
		if err := syncDirectory(directory); err != nil {
			return "", err
		}
	}
	if err := unix.Renameat2(unix.AT_FDCWD, temporary, unix.AT_FDCWD,
		destination, unix.RENAME_NOREPLACE); err != nil {
		return "", fmt.Errorf("commit native-session restore: %w", err)
	}
	committed = true
	if err := syncDirectory(root); err != nil {
		return "", err
	}
	if _, err := ValidateRestore(destination); err != nil {
		return "", err
	}
	return destination, nil
}

func ValidateRestore(directory string) (RestoreReceipt, error) {
	if err := requirePrivateDirectory(directory); err != nil {
		return RestoreReceipt{}, err
	}
	entries, err := os.ReadDir(directory)
	expected := []string{profileMarkerFile, "Default", restoreReceiptFile}
	// A restored user-data directory contains only the three exact entries.
	// Keep this explicit instead of accepting browser-created state.
	if err != nil || len(entries) != len(expected) {
		return RestoreReceipt{}, errors.New("invalid native-session restore inventory")
	}
	for index, name := range expected {
		if entries[index].Name() != name {
			return RestoreReceipt{}, errors.New("invalid native-session restore inventory")
		}
	}
	raw, err := readPrivateRegular(filepath.Join(directory, restoreReceiptFile), 1024*1024)
	if err != nil {
		return RestoreReceipt{}, err
	}
	var receipt RestoreReceipt
	if err := strictJSON(raw, &receipt); err != nil {
		return RestoreReceipt{}, err
	}
	if receipt.SchemaVersion != RestoreSchemaVersion ||
		!validGeneration(receipt.SourceGeneration) ||
		!validSlug(receipt.SourceDevice) || !validSlug(receipt.SourceProfile) ||
		receipt.RestoredAt.IsZero() ||
		receipt.Invocation != "explicit-chromium-restore-last-session-only" ||
		receipt.State != "prepared-not-opened" || len(receipt.Files) < 2 {
		return RestoreReceipt{}, errors.New("invalid native-session restore receipt")
	}
	marker, err := readPrivateRegular(filepath.Join(directory, profileMarkerFile), 256)
	if err != nil || string(marker) != profileMarkerContent {
		return RestoreReceipt{}, errors.New("invalid native-session restore marker")
	}
	preferences, err := readPrivateRegular(filepath.Join(directory, "Default", "Preferences"), 256)
	if err != nil || string(preferences) != "{}\n" {
		return RestoreReceipt{}, errors.New("native-session restore must not configure startup")
	}
	defaultEntries, err := os.ReadDir(filepath.Join(directory, "Default"))
	if err != nil || len(defaultEntries) != 2 ||
		defaultEntries[0].Name() != "Preferences" ||
		defaultEntries[1].Name() != "Sessions" {
		return RestoreReceipt{}, errors.New("invalid native-session Default inventory")
	}
	sessions := filepath.Join(directory, "Default", "Sessions")
	if err := requirePrivateDirectory(sessions); err != nil {
		return RestoreReceipt{}, err
	}
	sessionEntries, err := os.ReadDir(sessions)
	if err != nil || len(sessionEntries) != len(receipt.Files) {
		return RestoreReceipt{}, errors.New("native-session restored inventory mismatch")
	}
	for _, entry := range sessionEntries {
		if _, ok := nativeFileKind(entry.Name()); !ok || entry.IsDir() {
			return RestoreReceipt{}, errors.New("unexpected restored native session file")
		}
		record, exists := receipt.Files[entry.Name()]
		if !exists || record.Size <= 0 || record.Size > maxNativeFileBytes ||
			record.FormatVersion != cleartextSessionVersion ||
			record.CommandCount <= 0 || record.MarkerCount <= 0 {
			return RestoreReceipt{}, errors.New("unexpected restored native session file")
		}
		raw, err := readPrivateRegular(filepath.Join(sessions, entry.Name()), maxNativeFileBytes)
		if err != nil {
			return RestoreReceipt{}, err
		}
		sum := sha256.Sum256(raw)
		if int64(len(raw)) != record.Size || hex.EncodeToString(sum[:]) != record.SHA256 {
			return RestoreReceipt{}, errors.New("restored native session checksum mismatch")
		}
		parsed, err := inspectNativeSession(raw)
		if err != nil || parsed.FormatVersion != record.FormatVersion ||
			parsed.CommandCount != record.CommandCount ||
			parsed.MarkerCount != record.MarkerCount {
			return RestoreReceipt{}, errors.New("restored native session semantic mismatch")
		}
	}
	return receipt, nil
}

func (store *Store) List() ([]Manifest, error) {
	entries, err := os.ReadDir(store.generations)
	if err != nil {
		return nil, err
	}
	var manifests []Manifest
	for _, entry := range entries {
		if !entry.IsDir() || !validGeneration(entry.Name()) {
			continue
		}
		manifest, err := store.Validate(entry.Name())
		if err != nil {
			return nil, fmt.Errorf("validate %s: %w", entry.Name(), err)
		}
		manifests = append(manifests, manifest)
	}
	sort.Slice(manifests, func(i, j int) bool {
		return manifests[i].CapturedAt.Before(manifests[j].CapturedAt)
	})
	return manifests, nil
}

func (store *Store) Quarantine(generation, reason string) (string, error) {
	if !validGeneration(generation) || !validSlug(reason) {
		return "", errors.New("invalid capsule quarantine request")
	}
	source := filepath.Join(store.generations, generation)
	if info, err := os.Lstat(source); err != nil || !info.IsDir() ||
		info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("capsule generation does not exist")
	}
	suffix, err := generationID(time.Now().UTC())
	if err != nil {
		return "", err
	}
	destination := filepath.Join(store.quarantine, suffix+"-"+generation+"-"+reason)
	if err := unix.Renameat2(unix.AT_FDCWD, source, unix.AT_FDCWD,
		destination, unix.RENAME_NOREPLACE); err != nil {
		return "", fmt.Errorf("quarantine capsule generation: %w", err)
	}
	if err := syncDirectory(store.generations); err != nil {
		return "", err
	}
	if err := syncDirectory(store.quarantine); err != nil {
		return "", err
	}
	return destination, nil
}

func GuardRun(guardPath string, command func() error) error {
	if command == nil {
		return errors.New("guarded command is required")
	}
	absolute, err := filepath.Abs(guardPath)
	if err != nil {
		return err
	}
	guard, err := acquireGuard(absolute, unix.LOCK_SH)
	if err != nil {
		return err
	}
	defer releaseGuard(guard)
	return command()
}

func validateCapturePaths(request CaptureRequest) (string, string, error) {
	profileRoot, err := filepath.Abs(request.ProfileRoot)
	if err != nil {
		return "", "", err
	}
	if err := requirePrivateDirectory(profileRoot); err != nil {
		return "", "", err
	}
	sessions := filepath.Join(profileRoot, "Default", "Sessions")
	if err := requirePrivateDirectory(sessions); err != nil {
		return "", "", err
	}
	guard, err := filepath.Abs(request.GuardPath)
	if err != nil {
		return "", "", err
	}
	if relative, err := filepath.Rel(profileRoot, guard); err != nil {
		return "", "", err
	} else if relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", "", errors.New("session guard must be outside the browser profile")
	}
	return sessions, guard, nil
}

func readNativeSessions(directory string) (map[string][]byte, map[string]FileRecord, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, nil, err
	}
	if len(entries) < 2 || len(entries) > maxNativeFiles {
		return nil, nil, errors.New("invalid Chromium Sessions file count")
	}
	files := make(map[string][]byte)
	records := make(map[string]FileRecord)
	hasSession := false
	hasTabs := false
	var total int64
	for _, entry := range entries {
		kind, ok := nativeFileKind(entry.Name())
		if !ok || entry.IsDir() {
			return nil, nil, errors.New("unexpected Chromium Sessions entry")
		}
		hasSession = hasSession || kind == "Session"
		hasTabs = hasTabs || kind == "Tabs"
		raw, err := stableRead(filepath.Join(directory, entry.Name()))
		if err != nil {
			return nil, nil, err
		}
		total += int64(len(raw))
		if total > maxNativeTotalBytes {
			return nil, nil, errors.New("Chromium Sessions capsule exceeds total size limit")
		}
		sum := sha256.Sum256(raw)
		record, err := inspectNativeSession(raw)
		if err != nil {
			return nil, nil, fmt.Errorf("%s: %w", entry.Name(), err)
		}
		record.SHA256 = hex.EncodeToString(sum[:])
		record.Size = int64(len(raw))
		files[entry.Name()] = raw
		records[entry.Name()] = record
	}
	if !hasSession || !hasTabs {
		return nil, nil, errors.New("Chromium Sessions capsule requires both file families")
	}
	return files, records, nil
}

// inspectNativeSession independently implements the cleartext framing contract
// pinned at pinnedChromiumCommit. Version 5 is encrypted with OS crypt and is
// deliberately rejected: a raw capsule without that device's OS key would not
// be independently recoverable.
func inspectNativeSession(raw []byte) (FileRecord, error) {
	if len(raw) < 8 ||
		binary.LittleEndian.Uint32(raw[:4]) != sessionFileSignature {
		return FileRecord{}, errors.New("invalid Chromium session signature")
	}
	version := int32(binary.LittleEndian.Uint32(raw[4:8]))
	if version != cleartextSessionVersion {
		return FileRecord{}, fmt.Errorf(
			"unsupported Chromium session version %d; raw capsule requires independently restorable cleartext version 3",
			version,
		)
	}
	var commandCount int64
	var markerCount int64
	for offset := 8; offset < len(raw); {
		if len(raw)-offset < 2 {
			return FileRecord{}, errors.New("truncated Chromium session command size")
		}
		size := int(binary.LittleEndian.Uint16(raw[offset : offset+2]))
		if size < 1 || size > len(raw)-(offset+2) {
			return FileRecord{}, errors.New("invalid Chromium session command frame")
		}
		if raw[offset+2] == initialStateMarkerID {
			if size != 1 {
				return FileRecord{}, errors.New("invalid Chromium session marker")
			}
			markerCount++
		}
		commandCount++
		offset += 2 + size
	}
	if commandCount == 0 || markerCount == 0 {
		return FileRecord{}, errors.New("Chromium session lacks a complete initial-state marker")
	}
	return FileRecord{
		FormatVersion: version,
		CommandCount:  commandCount,
		MarkerCount:   markerCount,
	}, nil
}

func nativeFileKind(name string) (string, bool) {
	for _, prefix := range []string{"Session_", "Tabs_"} {
		if !strings.HasPrefix(name, prefix) || len(name) == len(prefix) {
			continue
		}
		if _, err := strconv.ParseUint(name[len(prefix):], 10, 64); err == nil {
			return strings.TrimSuffix(prefix, "_"), true
		}
	}
	return "", false
}

func stableRead(path string) ([]byte, error) {
	fileDescriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open native session file: %w", err)
	}
	file := os.NewFile(uintptr(fileDescriptor), filepath.Base(path))
	defer file.Close()
	before, err := file.Stat()
	if err != nil || !before.Mode().IsRegular() || before.Mode().Perm()&0077 != 0 ||
		before.Size() <= 0 || before.Size() > maxNativeFileBytes {
		return nil, errors.New("invalid native session file")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxNativeFileBytes+1))
	if err != nil {
		return nil, err
	}
	after, err := file.Stat()
	if err != nil || before.Size() != after.Size() ||
		!before.ModTime().Equal(after.ModTime()) || int64(len(raw)) != before.Size() {
		return nil, errors.New("native session file changed during capture")
	}
	return raw, nil
}

func acquireGuard(path string, operation int) (*os.File, error) {
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("session guard cannot be a symlink")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(file.Fd()), operation); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func releaseGuard(file *os.File) {
	if file == nil {
		return
	}
	_ = unix.Flock(int(file.Fd()), unix.LOCK_UN)
	_ = file.Close()
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
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' ||
			index > 0 && (character == '.' || character == '_' || character == '-') {
			continue
		}
		return false
	}
	return true
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

func readPrivateRegular(path string, limit int64) ([]byte, error) {
	if info, err := os.Lstat(path); err != nil || !info.Mode().IsRegular() ||
		info.Mode().Perm()&0077 != 0 || info.Size() < 0 || info.Size() > limit {
		return nil, errors.New("path is not a bounded private regular file")
	}
	return os.ReadFile(path)
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
