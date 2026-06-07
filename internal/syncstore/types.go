package syncstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type Kind string

const (
	KindTabs     Kind = "tabs"
	KindPassword Kind = "passwords"
	KindCookie   Kind = "cookies"
)

var allKinds = map[Kind]struct{}{
	KindTabs:     {},
	KindPassword: {},
	KindCookie:   {},
}

var kindAliases = map[string]Kind{
	"tab":       KindTabs,
	"tabs":      KindTabs,
	"password":  KindPassword,
	"passwords": KindPassword,
	"cookie":    KindCookie,
	"cookies":   KindCookie,
}

func ParseKind(value string) (Kind, error) {
	kind, ok := kindAliases[strings.TrimSpace(strings.ToLower(value))]
	if !ok {
		return "", fmt.Errorf("unknown record kind %q", value)
	}
	return kind, nil
}

func ParseKinds(values []string) (map[Kind]struct{}, error) {
	if len(values) == 0 {
		return nil, nil
	}
	kinds := make(map[Kind]struct{}, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			continue
		}
		kind, err := ParseKind(value)
		if err != nil {
			return nil, err
		}
		kinds[kind] = struct{}{}
	}
	if len(kinds) == 0 {
		return nil, nil
	}
	return kinds, nil
}

type PlainRecord struct {
	Kind         Kind            `json:"kind"`
	Key          string          `json:"key"`
	Version      int64           `json:"version"`
	UpdatedAt    time.Time       `json:"updated_at"`
	Deleted      bool            `json:"deleted,omitempty"`
	OriginDevice string          `json:"origin_device,omitempty"`
	Payload      json.RawMessage `json:"payload"`
}

type RecordEnvelope struct {
	Seq          int64           `json:"seq"`
	Kind         Kind            `json:"kind"`
	Key          string          `json:"key"`
	Version      int64           `json:"version"`
	UpdatedAt    time.Time       `json:"updated_at"`
	Deleted      bool            `json:"deleted,omitempty"`
	OriginDevice string          `json:"origin_device,omitempty"`
	Payload      json.RawMessage `json:"payload"`
}

type StoredRecord struct {
	Seq          int64     `json:"seq"`
	Kind         Kind      `json:"kind"`
	Key          string    `json:"key"`
	Version      int64     `json:"version"`
	UpdatedAt    time.Time `json:"updated_at"`
	Deleted      bool      `json:"deleted,omitempty"`
	OriginDevice string    `json:"origin_device,omitempty"`
	Nonce        string    `json:"nonce"`
	Ciphertext   string    `json:"ciphertext"`
}

type PushRequest struct {
	Device  string        `json:"device"`
	Records []PlainRecord `json:"records"`
}

type PushResponse struct {
	Accepted int   `json:"accepted"`
	NextSeq  int64 `json:"next_seq"`
}

type PullResponse struct {
	Records []RecordEnvelope `json:"records"`
	NextSeq int64            `json:"next_seq"`
}

func (record PlainRecord) validate() error {
	if _, ok := allKinds[record.Kind]; !ok {
		return fmt.Errorf("unknown record kind %q", record.Kind)
	}
	if strings.TrimSpace(record.Key) == "" {
		return errors.New("record key is required")
	}
	if len(record.Payload) == 0 {
		if record.Deleted {
			return nil
		}
		return errors.New("record payload is required")
	}
	if !json.Valid(record.Payload) {
		return errors.New("record payload must be valid JSON")
	}
	return nil
}

func (record StoredRecord) matches(kinds map[Kind]struct{}) bool {
	if len(kinds) == 0 {
		return true
	}
	_, ok := kinds[record.Kind]
	return ok
}
