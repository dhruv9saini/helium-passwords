package tabsnapshot

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	manifestFile    = "manifest.json"
	sessionFile     = "session.json"
	maxSessionBytes = 16 * 1024 * 1024
	maxWindows      = 100
	maxTabs         = 5000
	maxNavigations  = 100
)

type Store struct {
	root        string
	generations string
	quarantine  string
}

func Open(root string) (*Store, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("snapshot root is required")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve snapshot root: %w", err)
	}
	if abs == filepath.Clean(string(os.PathSeparator)) {
		return nil, errors.New("snapshot root cannot be the filesystem root")
	}
	generations := filepath.Join(abs, "generations")
	quarantine := filepath.Join(abs, "quarantine")
	for _, directory := range []string{abs, generations, quarantine} {
		if err := ensurePrivateDirectory(directory); err != nil {
			return nil, err
		}
	}
	return &Store{root: abs, generations: generations, quarantine: quarantine}, nil
}

func (store *Store) Capture(request CaptureRequest) (Manifest, error) {
	if err := validateCaptureRequest(request); err != nil {
		return Manifest{}, err
	}
	if request.CapturedAt.IsZero() {
		request.CapturedAt = time.Now().UTC()
	} else {
		request.CapturedAt = request.CapturedAt.UTC()
	}
	raw, err := json.MarshalIndent(request.Session, "", "  ")
	if err != nil {
		return Manifest{}, fmt.Errorf("encode session: %w", err)
	}
	raw = append(raw, '\n')
	if len(raw) > maxSessionBytes {
		return Manifest{}, fmt.Errorf("session exceeds %d bytes", maxSessionBytes)
	}

	generation, err := generationID(request.CapturedAt)
	if err != nil {
		return Manifest{}, err
	}
	parent := ""
	if latest, err := store.latestValid(); err == nil {
		parent = latest.Generation
	} else if !errors.Is(err, os.ErrNotExist) {
		return Manifest{}, err
	}
	sum := sha256.Sum256(raw)
	manifest := Manifest{
		SchemaVersion:    SchemaVersion,
		Generation:       generation,
		ParentGeneration: parent,
		Device:           request.Device,
		Profile:          request.Profile,
		BrowserVersion:   request.BrowserVersion,
		ChromiumVersion:  request.ChromiumVersion,
		CapturedAt:       request.CapturedAt,
		Reason:           request.Reason,
		Protected:        request.Protected,
		Validation:       "valid",
		Files: map[string]FileRecord{
			sessionFile: {SHA256: hex.EncodeToString(sum[:]), Size: int64(len(raw))},
		},
	}
	manifestRaw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return Manifest{}, fmt.Errorf("encode manifest: %w", err)
	}
	manifestRaw = append(manifestRaw, '\n')

	temporary := filepath.Join(store.generations, ".tmp-"+generation)
	final := filepath.Join(store.generations, generation)
	if err := os.Mkdir(temporary, 0700); err != nil {
		return Manifest{}, fmt.Errorf("create temporary generation: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	if err := writeSynced(filepath.Join(temporary, sessionFile), raw, 0600); err != nil {
		return Manifest{}, err
	}
	if err := writeSynced(filepath.Join(temporary, manifestFile), manifestRaw, 0600); err != nil {
		return Manifest{}, err
	}
	if err := syncDirectory(temporary); err != nil {
		return Manifest{}, err
	}
	if err := os.Rename(temporary, final); err != nil {
		return Manifest{}, fmt.Errorf("commit generation: %w", err)
	}
	if err := syncDirectory(store.generations); err != nil {
		return Manifest{}, err
	}
	committed = true
	if _, err := store.Validate(generation); err != nil {
		return Manifest{}, fmt.Errorf("validate committed generation: %w", err)
	}
	return manifest, nil
}

func (store *Store) Validate(generation string) (Manifest, error) {
	if !validGenerationID(generation) {
		return Manifest{}, errors.New("invalid generation id")
	}
	directory := filepath.Join(store.generations, generation)
	if err := validateGenerationInventory(directory); err != nil {
		return Manifest{}, err
	}
	manifestRaw, err := os.ReadFile(filepath.Join(directory, manifestFile))
	if err != nil {
		return Manifest{}, fmt.Errorf("read manifest: %w", err)
	}
	var manifest Manifest
	if err := decodeStrictJSON(manifestRaw, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode manifest: %w", err)
	}
	if manifest.SchemaVersion != SchemaVersion || manifest.Generation != generation ||
		manifest.Validation != "valid" || manifest.CapturedAt.IsZero() ||
		strings.TrimSpace(manifest.Device) == "" || strings.TrimSpace(manifest.Profile) == "" ||
		strings.TrimSpace(manifest.BrowserVersion) == "" ||
		strings.TrimSpace(manifest.ChromiumVersion) == "" ||
		strings.TrimSpace(manifest.Reason) == "" {
		return Manifest{}, errors.New("invalid manifest metadata")
	}
	if manifest.ParentGeneration != "" &&
		(!validGenerationID(manifest.ParentGeneration) || manifest.ParentGeneration == generation) {
		return Manifest{}, errors.New("invalid parent generation")
	}
	capturedTime, err := generationTime(generation)
	if err != nil || !capturedTime.Equal(manifest.CapturedAt) {
		return Manifest{}, errors.New("manifest capture time does not match generation")
	}
	record, ok := manifest.Files[sessionFile]
	if !ok || record.Size <= 0 || record.Size > maxSessionBytes || len(manifest.Files) != 1 {
		return Manifest{}, errors.New("invalid manifest file inventory")
	}
	raw, err := os.ReadFile(filepath.Join(directory, sessionFile))
	if err != nil {
		return Manifest{}, fmt.Errorf("read session: %w", err)
	}
	if int64(len(raw)) != record.Size {
		return Manifest{}, errors.New("session size mismatch")
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != record.SHA256 {
		return Manifest{}, errors.New("session hash mismatch")
	}
	var session Session
	if err := decodeStrictJSON(raw, &session); err != nil {
		return Manifest{}, fmt.Errorf("decode session: %w", err)
	}
	if err := ValidateSession(session); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func (store *Store) List() ([]Generation, error) {
	entries, err := os.ReadDir(store.generations)
	if err != nil {
		return nil, fmt.Errorf("list generations: %w", err)
	}
	var out []Generation
	for _, entry := range entries {
		if !entry.IsDir() || !validGenerationID(entry.Name()) {
			continue
		}
		manifest, validationErr := store.Validate(entry.Name())
		item := Generation{Manifest: manifest, Valid: validationErr == nil}
		if validationErr != nil {
			item.Manifest.Generation = entry.Name()
			item.Error = validationErr.Error()
			if raw, readErr := os.ReadFile(filepath.Join(store.generations, entry.Name(), manifestFile)); readErr == nil {
				_ = json.Unmarshal(raw, &item.Manifest)
				item.Manifest.Generation = entry.Name()
			}
		}
		if capturedAt, parseErr := generationTime(entry.Name()); parseErr == nil {
			item.Manifest.CapturedAt = capturedAt
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Manifest.CapturedAt.Equal(out[j].Manifest.CapturedAt) {
			return out[i].Manifest.Generation > out[j].Manifest.Generation
		}
		return out[i].Manifest.CapturedAt.After(out[j].Manifest.CapturedAt)
	})
	return out, nil
}

func (store *Store) Restore(generation string, destination string) error {
	if strings.TrimSpace(destination) == "" {
		return errors.New("restore destination is required")
	}
	manifest, err := store.Validate(generation)
	if err != nil {
		return fmt.Errorf("validate restore source: %w", err)
	}
	destination, err = filepath.Abs(destination)
	if err != nil {
		return fmt.Errorf("resolve restore destination: %w", err)
	}
	if _, err := os.Stat(destination); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return errors.New("restore destination already exists")
		}
		return fmt.Errorf("inspect restore destination: %w", err)
	}
	if relative, err := filepath.Rel(store.root, destination); err != nil {
		return fmt.Errorf("compare restore destination: %w", err)
	} else if relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("restore destination must be outside the snapshot store")
	}
	parent := filepath.Dir(destination)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return fmt.Errorf("create restore parent: %w", err)
	}
	temporary, err := os.MkdirTemp(parent, ".helium-tab-restore-")
	if err != nil {
		return fmt.Errorf("create restore staging directory: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	session, err := os.ReadFile(filepath.Join(store.generations, generation, sessionFile))
	if err != nil {
		return fmt.Errorf("read restore session: %w", err)
	}
	if err := writeSynced(filepath.Join(temporary, sessionFile), session, 0600); err != nil {
		return err
	}
	restoreManifest, err := json.MarshalIndent(RestoreManifest{
		SchemaVersion:    RestoreSchemaVersion,
		SourceGeneration: generation,
		SourceDevice:     manifest.Device,
		SourceProfile:    manifest.Profile,
		RestoredAt:       time.Now().UTC(),
		Validation:       "valid",
		Session:          manifest.Files[sessionFile],
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := writeSynced(filepath.Join(temporary, "restore-manifest.json"), append(restoreManifest, '\n'), 0600); err != nil {
		return err
	}
	if _, err := ValidateRestore(temporary); err != nil {
		return fmt.Errorf("validate staged disposable restore: %w", err)
	}
	if err := syncDirectory(temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return fmt.Errorf("commit disposable restore: %w", err)
	}
	if err := syncDirectory(parent); err != nil {
		return err
	}
	committed = true
	if _, err := ValidateRestore(destination); err != nil {
		return fmt.Errorf("validate committed disposable restore: %w", err)
	}
	return nil
}

// ValidateRestore authenticates the neutral disposable-state receipt and
// session without opening a browser or accepting a profile path.
func ValidateRestore(destination string) (RestoreManifest, error) {
	if strings.TrimSpace(destination) == "" {
		return RestoreManifest{}, errors.New("restore destination is required")
	}
	destination, err := filepath.Abs(destination)
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("resolve restore destination: %w", err)
	}
	if err := requirePrivateDirectory(destination); err != nil {
		return RestoreManifest{}, err
	}
	entries, err := os.ReadDir(destination)
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("list restore inventory: %w", err)
	}
	if len(entries) != 2 || entries[0].Name() != "restore-manifest.json" ||
		entries[1].Name() != sessionFile {
		return RestoreManifest{}, errors.New("invalid restore file inventory")
	}
	for _, name := range []string{"restore-manifest.json", sessionFile} {
		if err := requirePrivateRegularFile(filepath.Join(destination, name)); err != nil {
			return RestoreManifest{}, err
		}
	}
	rawManifest, err := os.ReadFile(filepath.Join(destination, "restore-manifest.json"))
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("read restore manifest: %w", err)
	}
	var manifest RestoreManifest
	if err := decodeStrictJSON(rawManifest, &manifest); err != nil {
		return RestoreManifest{}, fmt.Errorf("decode restore manifest: %w", err)
	}
	if manifest.SchemaVersion != RestoreSchemaVersion ||
		!validGenerationID(manifest.SourceGeneration) ||
		strings.TrimSpace(manifest.SourceDevice) == "" ||
		strings.TrimSpace(manifest.SourceProfile) == "" ||
		manifest.RestoredAt.IsZero() || manifest.Validation != "valid" ||
		manifest.Session.Size <= 0 || manifest.Session.Size > maxSessionBytes ||
		len(manifest.Session.SHA256) != sha256.Size*2 {
		return RestoreManifest{}, errors.New("invalid restore manifest metadata")
	}
	rawSession, err := os.ReadFile(filepath.Join(destination, sessionFile))
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("read restored session: %w", err)
	}
	if int64(len(rawSession)) != manifest.Session.Size {
		return RestoreManifest{}, errors.New("restored session size mismatch")
	}
	sum := sha256.Sum256(rawSession)
	if hex.EncodeToString(sum[:]) != manifest.Session.SHA256 {
		return RestoreManifest{}, errors.New("restored session hash mismatch")
	}
	var session Session
	if err := decodeStrictJSON(rawSession, &session); err != nil {
		return RestoreManifest{}, fmt.Errorf("decode restored session: %w", err)
	}
	if err := ValidateSession(session); err != nil {
		return RestoreManifest{}, err
	}
	return manifest, nil
}

// Quarantine atomically removes a suspect generation from retention and
// restore consideration without deleting any bytes. It is intentionally
// explicit: validation failures stop retention until an operator preserves
// the suspect generation here or repairs the underlying storage.
func (store *Store) Quarantine(generation string, reason string) (string, error) {
	if !validGenerationID(generation) {
		return "", errors.New("invalid generation id")
	}
	if !validSlug(reason) {
		return "", errors.New("quarantine reason must be a short slug")
	}
	source := filepath.Join(store.generations, generation)
	info, err := os.Stat(source)
	if err != nil {
		return "", fmt.Errorf("inspect quarantine source: %w", err)
	}
	if !info.IsDir() {
		return "", errors.New("quarantine source is not a generation directory")
	}
	random := make([]byte, 8)
	if _, err := io.ReadFull(rand.Reader, random); err != nil {
		return "", fmt.Errorf("generate quarantine id: %w", err)
	}
	name := time.Now().UTC().Format("20060102T150405.000000000Z") + "-" +
		generation + "-" + reason + "-" + hex.EncodeToString(random)
	destination := filepath.Join(store.quarantine, name)
	if err := os.Rename(source, destination); err != nil {
		return "", fmt.Errorf("quarantine generation: %w", err)
	}
	if err := syncDirectory(store.generations); err != nil {
		return "", err
	}
	if err := syncDirectory(store.quarantine); err != nil {
		return "", err
	}
	return destination, nil
}

func ValidateSession(session Session) error {
	if session.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported session schema %d", session.SchemaVersion)
	}
	if len(session.Windows) == 0 || len(session.Windows) > maxWindows {
		return fmt.Errorf("session must contain 1..%d windows", maxWindows)
	}
	tabCount := 0
	windowIDs := make(map[string]struct{})
	tabIDs := make(map[string]struct{})
	for _, window := range session.Windows {
		if window.ID == "" {
			return errors.New("window id is required")
		}
		if _, exists := windowIDs[window.ID]; exists {
			return fmt.Errorf("duplicate window id %q", window.ID)
		}
		windowIDs[window.ID] = struct{}{}
		if len(window.Tabs) == 0 || window.ActiveIndex < 0 || window.ActiveIndex >= len(window.Tabs) {
			return fmt.Errorf("window %q has invalid active tab", window.ID)
		}
		for _, tab := range window.Tabs {
			tabCount++
			if tabCount > maxTabs {
				return fmt.Errorf("session exceeds %d tabs", maxTabs)
			}
			if tab.ID == "" {
				return errors.New("tab id is required")
			}
			if _, exists := tabIDs[tab.ID]; exists {
				return fmt.Errorf("duplicate tab id %q", tab.ID)
			}
			tabIDs[tab.ID] = struct{}{}
			if len(tab.Navigations) == 0 || len(tab.Navigations) > maxNavigations ||
				tab.CurrentIndex < 0 || tab.CurrentIndex >= len(tab.Navigations) {
				return fmt.Errorf("tab %q has invalid navigation history", tab.ID)
			}
			for _, navigation := range tab.Navigations {
				parsed, err := url.Parse(navigation.URL)
				if err != nil || !allowedScheme(parsed.Scheme) {
					return fmt.Errorf("tab %q has disallowed URL", tab.ID)
				}
			}
		}
	}
	return nil
}

func validateCaptureRequest(request CaptureRequest) error {
	if strings.TrimSpace(request.Device) == "" || strings.TrimSpace(request.Profile) == "" {
		return errors.New("device and profile are required")
	}
	if strings.TrimSpace(request.BrowserVersion) == "" || strings.TrimSpace(request.ChromiumVersion) == "" {
		return errors.New("browser and Chromium versions are required")
	}
	if strings.TrimSpace(request.Reason) == "" {
		return errors.New("capture reason is required")
	}
	return ValidateSession(request.Session)
}

func (store *Store) latestValid() (Manifest, error) {
	items, err := store.List()
	if err != nil {
		return Manifest{}, err
	}
	for _, item := range items {
		if item.Valid {
			return item.Manifest, nil
		}
	}
	return Manifest{}, os.ErrNotExist
}

func generationID(capturedAt time.Time) (string, error) {
	random := make([]byte, 8)
	if _, err := io.ReadFull(rand.Reader, random); err != nil {
		return "", fmt.Errorf("generate id: %w", err)
	}
	return capturedAt.UTC().Format("20060102T150405.000000000Z") + "-" + hex.EncodeToString(random), nil
}

func validGenerationID(value string) bool {
	if value == "" || filepath.Base(value) != value || strings.HasPrefix(value, ".") {
		return false
	}
	_, err := generationTime(value)
	return err == nil
}

func validSlug(value string) bool {
	if len(value) == 0 || len(value) > 64 {
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

func generationTime(value string) (time.Time, error) {
	separator := strings.LastIndexByte(value, '-')
	if separator <= 0 || len(value)-separator-1 != 16 {
		return time.Time{}, errors.New("invalid generation id")
	}
	if _, err := hex.DecodeString(value[separator+1:]); err != nil {
		return time.Time{}, errors.New("invalid generation id")
	}
	capturedAt, err := time.Parse("20060102T150405.000000000Z", value[:separator])
	if err != nil {
		return time.Time{}, errors.New("invalid generation id")
	}
	return capturedAt.UTC(), nil
}

func allowedScheme(scheme string) bool {
	switch strings.ToLower(scheme) {
	case "http", "https", "chrome", "about":
		return true
	default:
		return false
	}
}

func writeSynced(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", filepath.Base(path), err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return fmt.Errorf("write %s: %w", filepath.Base(path), err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return fmt.Errorf("sync %s: %w", filepath.Base(path), err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close %s: %w", filepath.Base(path), err)
	}
	return nil
}

func validateGenerationInventory(directory string) error {
	if err := requirePrivateDirectory(directory); err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return fmt.Errorf("list generation inventory: %w", err)
	}
	if len(entries) != 2 || entries[0].Name() != manifestFile ||
		entries[1].Name() != sessionFile {
		return errors.New("invalid generation file inventory")
	}
	for _, name := range []string{manifestFile, sessionFile} {
		if err := requirePrivateRegularFile(filepath.Join(directory, name)); err != nil {
			return err
		}
	}
	return nil
}

func requirePrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect private directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("private path is not a non-symlink directory: %s", filepath.Base(path))
	}
	if info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("private directory is accessible by group or world: %s", filepath.Base(path))
	}
	return nil
}

func ensurePrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("private path is not a non-symlink directory: %s", filepath.Base(path))
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect private directory: %w", err)
	} else if err := os.MkdirAll(path, 0700); err != nil {
		return fmt.Errorf("create snapshot directory: %w", err)
	}
	if err := os.Chmod(path, 0700); err != nil {
		return fmt.Errorf("secure snapshot directory: %w", err)
	}
	return requirePrivateDirectory(path)
}

func requirePrivateRegularFile(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect private file: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("private path is not a non-symlink regular file: %s", filepath.Base(path))
	}
	if info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("private file is accessible by group or world: %s", filepath.Base(path))
	}
	return nil
}

func decodeStrictJSON(raw []byte, destination any) error {
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("unexpected trailing JSON value")
		}
		return fmt.Errorf("decode trailing JSON: %w", err)
	}
	return nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open directory for sync: %w", err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("sync directory: %w", err)
	}
	return nil
}
