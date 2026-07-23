package tabjournal

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const catalogTemplate = `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex,nofollow">
<title>Helium tab journal recovery catalog</title>
<h1>Helium tab journal recovery catalog</h1>
<p>This catalog never opens tabs automatically. Select links manually in a disposable browser.</p>
{{range .Windows}}<section><h2>Window {{.Index}}</h2>
{{if .Groups}}<ul>{{range .Groups}}<li>Group {{.ID}}: {{.Title}} ({{.Color}}{{if .Collapsed}}, collapsed{{end}})</li>{{end}}</ul>{{end}}<ol>
{{range .Tabs}}<li>{{if .Pinned}}[pinned] {{end}}{{if .Active}}[active] {{end}}<a href="{{.URL}}">{{if .Title}}{{.Title}}{{else}}{{.URL}}{{end}}</a> <code>{{.URL}}</code>{{if .Group}} — group {{.Group}}{{end}}</li>
{{end}}</ol></section>{{end}}`

func (store *Store) RestoreCatalog(generation, disposableRoot, profile string) (string, error) {
	if !validSlug(profile) || !strings.HasPrefix(profile, "drill-journal-") {
		return "", errors.New("journal restore profile must be drill-journal-*")
	}
	manifest, segment, record, checkpoint, err := store.LatestCheckpoint(generation)
	if err != nil {
		return "", err
	}
	root, err := filepath.Abs(disposableRoot)
	if err != nil || requirePrivateDirectory(root) != nil {
		return "", errors.New("invalid journal disposable root")
	}
	marker, err := readPrivate(filepath.Join(root, rootMarkerFile), 256)
	if err != nil || string(marker) != rootMarkerContent {
		return "", errors.New("invalid journal disposable root marker")
	}
	destination := filepath.Join(root, profile)
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("journal restore target already exists")
	}
	temporary, err := os.MkdirTemp(root, ".journal-restore-")
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
	var catalog strings.Builder
	tmpl, err := template.New("catalog").Parse(catalogTemplate)
	if err != nil {
		return "", err
	}
	if err := tmpl.Execute(&catalog, checkpoint); err != nil {
		return "", err
	}
	catalogRaw := []byte(catalog.String())
	sum := sha256.Sum256(catalogRaw)
	receipt := RestoreReceipt{
		SchemaVersion:    RestoreSchemaVersion,
		SourceGeneration: manifest.Generation,
		SourceDevice:     manifest.Device,
		SourceProfile:    manifest.Profile,
		SourceSegment:    segment,
		SourceFinalHash:  record.FinalHash,
		RestoredAt:       time.Now().UTC(),
		State:            "prepared-not-opened",
		CatalogSHA256:    hex.EncodeToString(sum[:]),
	}
	receiptRaw, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	for name, raw := range map[string][]byte{
		restoreMarkerFile:  []byte(restoreMarker),
		catalogFile:        catalogRaw,
		restoreReceiptFile: append(receiptRaw, '\n'),
	} {
		if err := writeNewSynced(filepath.Join(temporary, name), raw, 0600); err != nil {
			return "", err
		}
	}
	if err := syncDirectory(temporary); err != nil {
		return "", err
	}
	if err := unix.Renameat2(unix.AT_FDCWD, temporary, unix.AT_FDCWD,
		destination, unix.RENAME_NOREPLACE); err != nil {
		return "", fmt.Errorf("commit journal restore: %w", err)
	}
	committed = true
	if err := syncDirectory(root); err != nil {
		return "", err
	}
	if _, err := ValidateCatalog(destination); err != nil {
		return "", err
	}
	return destination, nil
}

func ValidateCatalog(directory string) (RestoreReceipt, error) {
	if err := requirePrivateDirectory(directory); err != nil {
		return RestoreReceipt{}, err
	}
	entries, err := os.ReadDir(directory)
	expected := []string{restoreMarkerFile, restoreReceiptFile, catalogFile}
	if err != nil || len(entries) != len(expected) {
		return RestoreReceipt{}, errors.New("invalid journal restore inventory")
	}
	for index, name := range expected {
		if entries[index].Name() != name {
			return RestoreReceipt{}, errors.New("invalid journal restore inventory")
		}
	}
	marker, err := readPrivate(filepath.Join(directory, restoreMarkerFile), 256)
	if err != nil || string(marker) != restoreMarker {
		return RestoreReceipt{}, errors.New("invalid journal restore marker")
	}
	raw, err := readPrivate(filepath.Join(directory, restoreReceiptFile), 1024*1024)
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
		!validSegmentName(receipt.SourceSegment) ||
		!validSHA256(receipt.SourceFinalHash) ||
		receipt.RestoredAt.IsZero() || receipt.State != "prepared-not-opened" ||
		!validSHA256(receipt.CatalogSHA256) {
		return RestoreReceipt{}, errors.New("invalid journal restore receipt")
	}
	catalog, err := readPrivate(filepath.Join(directory, catalogFile), 16*1024*1024)
	if err != nil {
		return RestoreReceipt{}, err
	}
	sum := sha256.Sum256(catalog)
	if hex.EncodeToString(sum[:]) != receipt.CatalogSHA256 {
		return RestoreReceipt{}, errors.New("journal recovery catalog checksum mismatch")
	}
	return receipt, nil
}
