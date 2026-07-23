package tabsnapshot

import "time"

const ManifestSchemaVersion = 1
const SessionSchemaVersion = 2
const LegacySessionSchemaVersion = 1
const SchemaVersion = SessionSchemaVersion
const RestoreSchemaVersion = 1
const BrowserRestoreSchemaVersion = 2

const (
	GroupMetadataComplete          = "complete"
	GroupMetadataLegacyUnavailable = "legacy-unavailable"
	HistoryBounded                 = "bounded"
	HistoryCurrentOnlyUnloaded     = "current-only-unloaded"
	HistoryLegacyBounded           = "legacy-bounded"
	BrowserRestoreInvocation       = "explicit-command-line-only"
)

type Session struct {
	SchemaVersion int      `json:"schema_version"`
	Windows       []Window `json:"windows"`
}

type Window struct {
	ID          string  `json:"id"`
	ActiveIndex int     `json:"active_index"`
	Groups      []Group `json:"groups"`
	Tabs        []Tab   `json:"tabs"`
}

type Group struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Color         string `json:"color"`
	Collapsed     bool   `json:"collapsed"`
	MetadataState string `json:"metadata_state"`
}

type Tab struct {
	ID           string       `json:"id"`
	Pinned       bool         `json:"pinned"`
	Group        string       `json:"group"`
	HistoryState string       `json:"history_state"`
	CurrentIndex int          `json:"current_index"`
	Navigations  []Navigation `json:"navigations"`
}

type Navigation struct {
	URL   string `json:"url"`
	Title string `json:"title"`
}

type CaptureRequest struct {
	Device          string
	Profile         string
	BrowserVersion  string
	ChromiumVersion string
	Reason          string
	CapturedAt      time.Time
	Protected       bool
	Session         Session
}

type FileRecord struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Manifest struct {
	SchemaVersion    int                   `json:"schema_version"`
	Generation       string                `json:"generation"`
	ParentGeneration string                `json:"parent_generation,omitempty"`
	Device           string                `json:"device"`
	Profile          string                `json:"profile"`
	BrowserVersion   string                `json:"browser_version"`
	ChromiumVersion  string                `json:"chromium_version"`
	CapturedAt       time.Time             `json:"captured_at"`
	Reason           string                `json:"reason"`
	Protected        bool                  `json:"protected,omitempty"`
	Validation       string                `json:"validation"`
	Files            map[string]FileRecord `json:"files"`
}

type Generation struct {
	Manifest Manifest
	Valid    bool
	Error    string
}

type RetentionPlan struct {
	Keep   []string
	Delete []string
}

type RestoreManifest struct {
	SchemaVersion    int        `json:"schema_version"`
	SourceGeneration string     `json:"source_generation"`
	SourceDevice     string     `json:"source_device"`
	SourceProfile    string     `json:"source_profile"`
	RestoredAt       time.Time  `json:"restored_at"`
	Validation       string     `json:"validation"`
	Session          FileRecord `json:"session"`
}

type BrowserRestoreManifest struct {
	SchemaVersion    int        `json:"schema_version"`
	SourceGeneration string     `json:"source_generation"`
	SourceDevice     string     `json:"source_device"`
	SourceProfile    string     `json:"source_profile"`
	SourceSession    FileRecord `json:"source_session"`
	Preferences      FileRecord `json:"preferences"`
	WindowCount      int        `json:"window_count"`
	TabCount         int        `json:"tab_count"`
	GroupCount       int        `json:"group_count"`
	Invocation       string     `json:"invocation"`
	PreparedAt       time.Time  `json:"prepared_at"`
	State            string     `json:"state"`
}
