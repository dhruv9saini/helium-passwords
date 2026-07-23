package tabjournal

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

const maxSegmentBytes int64 = 128 * 1024 * 1024
const maxEventsPerSegment = 100000

func onlineBackup(source, destination string) error {
	for _, path := range []string{source, destination} {
		if strings.ContainsAny(path, "'\n\r\x00") {
			return errors.New("SQLite path contains an unsupported character")
		}
	}
	sourceURI := source
	if filepath.Base(source) != "active.sqlite" {
		sourceURI = (&url.URL{
			Scheme:   "file",
			Path:     source,
			RawQuery: "immutable=1",
		}).String()
	}
	command := exec.Command("sqlite3", sourceURI,
		".timeout 5000", ".backup '"+destination+"'")
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("SQLite online backup: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return os.Chmod(destination, 0600)
}

func readEvents(path string) ([]Event, error) {
	if err := requirePrivateRegular(path, maxSegmentBytes); err != nil {
		return nil, err
	}
	databaseURI := (&url.URL{
		Scheme:   "file",
		Path:     path,
		RawQuery: "immutable=1",
	}).String()
	query := `SELECT epoch, sequence, occurred_at_unix_millis, kind, payload_json, previous_sha256, sha256 FROM events ORDER BY sequence;`
	integrity := exec.Command("sqlite3", "-readonly", "-noheader", databaseURI,
		"PRAGMA query_only=ON; PRAGMA integrity_check;")
	check, err := integrity.Output()
	if err != nil || string(check) != "ok\n" {
		return nil, errors.New("SQLite journal integrity check failed")
	}
	command := exec.Command("sqlite3", "-readonly", "-json", databaseURI, query)
	raw, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("query SQLite journal: %w", err)
	}
	var events []Event
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&events); err != nil {
		return nil, fmt.Errorf("decode SQLite journal events: %w", err)
	}
	if len(events) == 0 || len(events) > maxEventsPerSegment {
		return nil, errors.New("invalid SQLite journal event count")
	}
	return events, nil
}

func validateSegment(path string) (SegmentRecord, Checkpoint, error) {
	events, err := readEvents(path)
	if err != nil {
		return SegmentRecord{}, Checkpoint{}, err
	}
	var lastCheckpoint Checkpoint
	epoch := events[0].Epoch
	previous := ""
	for index, event := range events {
		if !validIdentifier(event.Epoch) || event.Epoch != epoch ||
			event.Sequence != int64(index+1) ||
			event.OccurredAtUnixMillis == "" ||
			event.Kind == "" || len(event.Kind) > 64 ||
			event.PreviousSHA256 != previous || !validSHA256(event.SHA256) {
			return SegmentRecord{}, Checkpoint{}, errors.New("invalid tab journal event sequence")
		}
		if _, err := strconv.ParseInt(event.OccurredAtUnixMillis, 10, 64); err != nil {
			return SegmentRecord{}, Checkpoint{}, errors.New("invalid tab journal timestamp")
		}
		calculated := eventHash(event)
		if calculated != event.SHA256 {
			return SegmentRecord{}, Checkpoint{}, errors.New("tab journal hash-chain mismatch")
		}
		if event.Kind == "initial-checkpoint" || event.Kind == "checkpoint" ||
			event.Kind == "final-checkpoint" || event.Kind == "heartbeat" {
			checkpoint, err := parseCheckpoint(event.PayloadJSON)
			if err != nil {
				return SegmentRecord{}, Checkpoint{}, err
			}
			lastCheckpoint = checkpoint
		} else {
			return SegmentRecord{}, Checkpoint{}, errors.New("unknown tab journal event kind")
		}
		previous = event.SHA256
	}
	if events[0].Kind != "initial-checkpoint" || len(lastCheckpoint.Windows) == 0 {
		return SegmentRecord{}, Checkpoint{}, errors.New("tab journal epoch lacks a usable initial/current checkpoint")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return SegmentRecord{}, Checkpoint{}, err
	}
	sum := sha256.Sum256(raw)
	return SegmentRecord{
		SHA256:                   hex.EncodeToString(sum[:]),
		Size:                     int64(len(raw)),
		Epoch:                    epoch,
		FirstSeq:                 1,
		LastSeq:                  events[len(events)-1].Sequence,
		EventCount:               int64(len(events)),
		FinalHash:                previous,
		LastOccurredAtUnixMillis: events[len(events)-1].OccurredAtUnixMillis,
	}, lastCheckpoint, nil
}

func eventHash(event Event) string {
	value := event.PreviousSHA256 + "\n" + event.Epoch + "\n" +
		strconv.FormatInt(event.Sequence, 10) + "\n" +
		event.OccurredAtUnixMillis + "\n" + event.Kind + "\n" +
		event.PayloadJSON
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func parseCheckpoint(raw string) (Checkpoint, error) {
	if len(raw) == 0 || len(raw) > 8*1024*1024 || !utf8.ValidString(raw) {
		return Checkpoint{}, errors.New("invalid tab journal checkpoint size")
	}
	var checkpoint Checkpoint
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&checkpoint); err != nil {
		return Checkpoint{}, fmt.Errorf("decode tab journal checkpoint: %w", err)
	}
	if checkpoint.SchemaVersion != SchemaVersion ||
		len(checkpoint.Windows) == 0 || len(checkpoint.Windows) > 100 {
		return Checkpoint{}, errors.New("invalid tab journal checkpoint")
	}
	total := 0
	for windowIndex, window := range checkpoint.Windows {
		if window.Index != windowIndex || window.Groups == nil ||
			len(window.Tabs) == 0 {
			return Checkpoint{}, errors.New("invalid tab journal window")
		}
		groups := make(map[string]Group)
		for _, group := range window.Groups {
			if !validIdentifier(group.ID) || len(group.Title) > 4096 ||
				!utf8.ValidString(group.Title) || !validGroupColor(group.Color) {
				return Checkpoint{}, errors.New("invalid tab journal group")
			}
			if _, exists := groups[group.ID]; exists {
				return Checkpoint{}, errors.New("duplicate tab journal group")
			}
			groups[group.ID] = group
		}
		active := 0
		seenUnpinned := false
		groupFirst := make(map[string]int)
		groupLast := make(map[string]int)
		groupCount := make(map[string]int)
		for tabIndex, tab := range window.Tabs {
			total++
			if total > 5000 || tab.Index != tabIndex || !validURL(tab.URL) ||
				len(tab.Title) > 4096 || !utf8.ValidString(tab.Title) ||
				len(tab.Group) > 128 || !utf8.ValidString(tab.Group) {
				return Checkpoint{}, errors.New("invalid tab journal tab")
			}
			if tab.Active {
				active++
			}
			if tab.Pinned && seenUnpinned {
				return Checkpoint{}, errors.New("invalid pinned tab order")
			}
			if !tab.Pinned {
				seenUnpinned = true
			}
			if tab.Group != "" {
				if tab.Pinned {
					return Checkpoint{}, errors.New("pinned tab belongs to a group")
				}
				if _, exists := groups[tab.Group]; !exists {
					return Checkpoint{}, errors.New("tab references unknown journal group")
				}
				if groupCount[tab.Group] == 0 {
					groupFirst[tab.Group] = tabIndex
				}
				groupLast[tab.Group] = tabIndex
				groupCount[tab.Group]++
			}
		}
		if active != 1 {
			return Checkpoint{}, errors.New("tab journal window must have one active tab")
		}
		for groupID := range groups {
			if groupCount[groupID] == 0 ||
				groupLast[groupID]-groupFirst[groupID]+1 != groupCount[groupID] {
				return Checkpoint{}, errors.New("journal group is empty or non-contiguous")
			}
		}
	}
	return checkpoint, nil
}

func validURL(value string) bool {
	if len(value) == 0 || len(value) > 8192 || !utf8.ValidString(value) {
		return false
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return false
	}
	if parsed.Scheme == "" {
		return false
	}
	return (parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Host != ""
}

func validGroupColor(value string) bool {
	switch value {
	case "grey", "blue", "red", "yellow", "green", "pink", "purple",
		"cyan", "orange":
		return true
	default:
		return false
	}
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && value == strings.ToLower(value)
}

func requirePrivateRegular(path string, limit int64) error {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 ||
		info.Size() <= 0 || info.Size() > limit {
		return errors.New("path is not a bounded private regular file")
	}
	return nil
}

func validIdentifier(value string) bool {
	if value == "" || len(value) > 128 || !utf8.ValidString(value) {
		return false
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return false
		}
	}
	return filepath.Base(value) == value
}
