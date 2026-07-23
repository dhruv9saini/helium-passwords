package tabjournal

import "time"

const SchemaVersion = 1
const StoreSchemaVersion = 2
const RestoreSchemaVersion = 1

type Event struct {
	Epoch                string `json:"epoch"`
	Sequence             int64  `json:"sequence"`
	OccurredAtUnixMillis string `json:"occurred_at_unix_millis"`
	Kind                 string `json:"kind"`
	PayloadJSON          string `json:"payload_json"`
	PreviousSHA256       string `json:"previous_sha256"`
	SHA256               string `json:"sha256"`
}

type Tab struct {
	Index  int    `json:"index"`
	Active bool   `json:"active"`
	Pinned bool   `json:"pinned"`
	Group  string `json:"group"`
	URL    string `json:"url"`
	Title  string `json:"title"`
}

type Group struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Color     string `json:"color"`
	Collapsed bool   `json:"collapsed"`
}

type Window struct {
	Index  int     `json:"index"`
	Groups []Group `json:"groups"`
	Tabs   []Tab   `json:"tabs"`
}

type Checkpoint struct {
	SchemaVersion int      `json:"schema_version"`
	Windows       []Window `json:"windows"`
}

type SegmentRecord struct {
	SHA256                   string `json:"sha256"`
	Size                     int64  `json:"size"`
	Epoch                    string `json:"epoch"`
	FirstSeq                 int64  `json:"first_sequence"`
	LastSeq                  int64  `json:"last_sequence"`
	EventCount               int64  `json:"event_count"`
	FinalHash                string `json:"final_hash"`
	LastOccurredAtUnixMillis string `json:"last_occurred_at_unix_millis"`
}

type Manifest struct {
	SchemaVersion int                      `json:"schema_version"`
	Generation    string                   `json:"generation"`
	Device        string                   `json:"device"`
	Profile       string                   `json:"profile"`
	CapturedAt    time.Time                `json:"captured_at"`
	Protected     bool                     `json:"protected"`
	Format        string                   `json:"format"`
	Segments      map[string]SegmentRecord `json:"segments"`
}

type RestoreReceipt struct {
	SchemaVersion    int       `json:"schema_version"`
	SourceGeneration string    `json:"source_generation"`
	SourceDevice     string    `json:"source_device"`
	SourceProfile    string    `json:"source_profile"`
	SourceSegment    string    `json:"source_segment"`
	SourceFinalHash  string    `json:"source_final_hash"`
	RestoredAt       time.Time `json:"restored_at"`
	State            string    `json:"state"`
	CatalogSHA256    string    `json:"catalog_sha256"`
}

type CaptureRequest struct {
	JournalRoot string
	Device      string
	Profile     string
	CapturedAt  time.Time
	Protected   bool
}

type RetentionPlan struct {
	Keep   []string `json:"keep"`
	Delete []string `json:"delete"`
}
