package syncstore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Counter is encoded as a decimal JSON string. Chromium's base::Value only
// represents JSON integers up to 32 bits, so using a number would silently lose
// precision before the int64 sequence space is exhausted.
type Counter int64

func (counter Counter) MarshalJSON() ([]byte, error) {
	return json.Marshal(strconv.FormatInt(int64(counter), 10))
}

func (counter *Counter) UnmarshalJSON(raw []byte) error {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return errors.New("counter must be a decimal JSON string")
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < 0 {
		return errors.New("counter must be a non-negative int64")
	}
	*counter = Counter(parsed)
	return nil
}

type Kind string

const (
	KindPassword Kind = "passwords"
	KindCookie   Kind = "cookies"
)

var allKinds = map[Kind]struct{}{
	KindPassword: {},
	KindCookie:   {},
}

func ParseKind(value string) (Kind, error) {
	kind := Kind(strings.TrimSpace(strings.ToLower(value)))
	if _, ok := allKinds[kind]; !ok {
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
		kind, err := ParseKind(value)
		if err != nil {
			return nil, err
		}
		kinds[kind] = struct{}{}
	}
	return kinds, nil
}

// PlainMutation and PlainRecord exist only on an authenticated client. They
// must never be accepted or returned by the server HTTP API.
type PlainMutation struct {
	Kind    Kind
	Key     string
	Deleted bool
	Payload json.RawMessage
}

type PlainRecord struct {
	Seq      Counter
	Kind     Kind
	Key      string
	Revision Counter
	Deleted  bool
	DeviceID string
	KeyID    string
	Payload  json.RawMessage
}

type PlainPullResponse struct {
	Records []PlainRecord
	NextSeq Counter
}

// OpaqueMutation is the complete server write surface. Ciphertext is an
// AES-256-GCM payload authenticated against all of the visible metadata.
type OpaqueMutation struct {
	Kind             Kind    `json:"kind"`
	Key              string  `json:"key"`
	ExpectedRevision Counter `json:"expected_revision"`
	Deleted          bool    `json:"deleted"`
	KeyID            string  `json:"key_id"`
	Nonce            string  `json:"nonce"`
	Ciphertext       string  `json:"ciphertext"`
}

type OpaqueRecord struct {
	Seq        Counter `json:"seq"`
	Kind       Kind    `json:"kind"`
	Key        string  `json:"key"`
	Revision   Counter `json:"revision"`
	Deleted    bool    `json:"deleted"`
	DeviceID   string  `json:"device_id"`
	KeyID      string  `json:"key_id"`
	Nonce      string  `json:"nonce"`
	Ciphertext string  `json:"ciphertext"`
}

type PushRequest struct {
	Mutations []OpaqueMutation `json:"mutations"`
}

type PushResponse struct {
	Records []OpaqueRecord `json:"records"`
	NextSeq Counter        `json:"next_seq"`
}

type PullResponse struct {
	Records []OpaqueRecord `json:"records"`
	NextSeq Counter        `json:"next_seq"`
}

type KeyTransitionRequest struct {
	ExpectedKeyID string `json:"expected_key_id"`
	NewKeyID      string `json:"new_key_id"`
}

type KeyTransitionResponse struct {
	ActiveKeyID   string `json:"active_key_id"`
	StagedKeyID   string `json:"staged_key_id"`
	RetiringKeyID string `json:"retiring_key_id"`
}

type KeyAcknowledgementRequest struct {
	KeyID           string  `json:"key_id"`
	AcknowledgedSeq Counter `json:"acknowledged_seq"`
}

type KeyRetirementRequest struct {
	ActiveKeyID   string `json:"active_key_id"`
	RetiringKeyID string `json:"retiring_key_id"`
}

type CredentialStageRequest struct {
	NewTokenSHA256 string `json:"new_token_sha256"`
}

type EnrollmentCompleteRequest struct {
	AcknowledgedSeq Counter `json:"acknowledged_seq"`
}

type EnrollmentCompleteResponse struct {
	Phase EnrollmentPhase `json:"phase"`
}

type ConflictError struct {
	Kind            Kind
	Key             string
	Expected        Counter
	CurrentRevision Counter
}

func (err *ConflictError) Error() string {
	return fmt.Sprintf("revision conflict for %s/%s: expected %d, current %d",
		err.Kind, err.Key, err.Expected, err.CurrentRevision)
}

func (mutation OpaqueMutation) validate() error {
	if _, ok := allKinds[mutation.Kind]; !ok {
		return fmt.Errorf("unknown record kind %q", mutation.Kind)
	}
	if strings.TrimSpace(mutation.Key) == "" {
		return errors.New("record key is required")
	}
	if strings.TrimSpace(mutation.KeyID) == "" {
		return errors.New("key_id is required")
	}
	if err := validateEncodedCiphertext(mutation.Nonce, mutation.Ciphertext); err != nil {
		return err
	}
	return nil
}

func (record OpaqueRecord) validate() error {
	if record.Seq <= 0 {
		return errors.New("seq must be positive")
	}
	if record.Revision <= 0 {
		return errors.New("revision must be positive")
	}
	if strings.TrimSpace(record.DeviceID) == "" {
		return errors.New("device_id is required")
	}
	return OpaqueMutation{
		Kind: record.Kind, Key: record.Key, KeyID: record.KeyID,
		Nonce: record.Nonce, Ciphertext: record.Ciphertext,
	}.validate()
}

func validateEncodedCiphertext(encodedNonce, encodedCiphertext string) error {
	nonce, err := base64.StdEncoding.DecodeString(encodedNonce)
	if err != nil || len(nonce) != clientNonceLength {
		return fmt.Errorf("nonce must be raw-base64 encoded %d bytes", clientNonceLength)
	}
	ciphertext, err := base64.StdEncoding.DecodeString(encodedCiphertext)
	if err != nil || len(ciphertext) < 16 {
		return errors.New("ciphertext must be raw-base64 encoded authenticated data")
	}
	return nil
}

func (record OpaqueRecord) matches(kinds map[Kind]struct{}) bool {
	if len(kinds) == 0 {
		return true
	}
	_, ok := kinds[record.Kind]
	return ok
}

func strictDecode(raw []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("unexpected trailing JSON value")
		}
		return err
	}
	return nil
}
