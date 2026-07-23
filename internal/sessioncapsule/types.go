package sessioncapsule

import "time"

const SchemaVersion = 1
const RestoreSchemaVersion = 1

type CaptureRequest struct {
	ProfileRoot string
	GuardPath   string
	Device      string
	Profile     string
	CapturedAt  time.Time
	Protected   bool
}

type FileRecord struct {
	SHA256        string `json:"sha256"`
	Size          int64  `json:"size"`
	FormatVersion int32  `json:"format_version"`
	CommandCount  int64  `json:"command_count"`
	MarkerCount   int64  `json:"marker_count"`
}

type Manifest struct {
	SchemaVersion  int                   `json:"schema_version"`
	Generation     string                `json:"generation"`
	Device         string                `json:"device"`
	Profile        string                `json:"profile"`
	CapturedAt     time.Time             `json:"captured_at"`
	Protected      bool                  `json:"protected"`
	Format         string                `json:"format"`
	Validation     string                `json:"validation"`
	ChromiumCommit string                `json:"chromium_commit"`
	Files          map[string]FileRecord `json:"files"`
}

type RestoreReceipt struct {
	SchemaVersion    int                   `json:"schema_version"`
	SourceGeneration string                `json:"source_generation"`
	SourceDevice     string                `json:"source_device"`
	SourceProfile    string                `json:"source_profile"`
	RestoredAt       time.Time             `json:"restored_at"`
	Invocation       string                `json:"invocation"`
	State            string                `json:"state"`
	Files            map[string]FileRecord `json:"files"`
}

type RetentionPlan struct {
	Keep   []string `json:"keep"`
	Delete []string `json:"delete"`
}
