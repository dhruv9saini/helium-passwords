package syncstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Client struct {
	mu      sync.Mutex
	baseURL string
	token   string
	http    *http.Client
	state   *ClientState
}

type ProtocolError struct {
	StatusCode      int
	Code            string
	Message         string
	Kind            Kind
	Key             string
	CurrentRevision Counter
}

func (err *ProtocolError) Error() string {
	if err.Code == "revision_conflict" {
		return fmt.Sprintf("%s: %s (current revision %d)", http.StatusText(err.StatusCode), err.Message, err.CurrentRevision)
	}
	return fmt.Sprintf("%s: %s", http.StatusText(err.StatusCode), err.Message)
}

func NewClient(baseURL, token, statePath string) (*Client, error) {
	parsedURL, err := url.Parse(baseURL)
	if err != nil || parsedURL.Host == "" || parsedURL.User != nil ||
		(parsedURL.Scheme != "https" &&
			!(parsedURL.Scheme == "http" && isLoopbackHost(parsedURL.Hostname()))) {
		return nil, errors.New("base URL must be HTTPS or loopback HTTP without user info")
	}
	if err := validateToken(token); err != nil {
		return nil, err
	}
	state, err := LoadClientState(statePath)
	if err != nil {
		return nil, err
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"), token: token,
		http: &http.Client{Timeout: 15 * time.Second}, state: state,
	}, nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

// Push encrypts local mutations and accepts only server-returned, authenticated
// mutation results. An empty mutation set is a local no-op and performs no HTTP.
func (client *Client) Push(ctx context.Context, mutations []PlainMutation) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.pushLocked(ctx, mutations)
}

func (client *Client) pushLocked(ctx context.Context, mutations []PlainMutation) (PlainPullResponse, error) {
	if len(mutations) == 0 {
		return PlainPullResponse{Records: []PlainRecord{}, NextSeq: client.state.Sequence}, nil
	}
	if client.state.Phase != PhaseActive {
		return PlainPullResponse{}, errors.New("pending join device cannot publish before verified enrollment")
	}
	activeKey, err := client.state.decodedKey(client.state.ActiveKeyID)
	if err != nil {
		return PlainPullResponse{}, err
	}
	opaque := make([]OpaqueMutation, 0, len(mutations))
	seen := make(map[string]struct{}, len(mutations))
	for _, mutation := range mutations {
		identity := recordIdentity(mutation.Kind, mutation.Key)
		if _, duplicate := seen[identity]; duplicate {
			return PlainPullResponse{}, fmt.Errorf("duplicate mutation for %s/%s", mutation.Kind, mutation.Key)
		}
		seen[identity] = struct{}{}
		revision := client.state.revision(mutation.Kind, mutation.Key) + 1
		encrypted, err := encryptClientPayload(activeKey, client.state.DeviceID, client.state.ActiveKeyID, mutation, revision)
		if err != nil {
			return PlainPullResponse{}, err
		}
		opaque = append(opaque, encrypted)
	}
	var response PushResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/records/push", PushRequest{Mutations: opaque}, &response); err != nil {
		return PlainPullResponse{}, err
	}
	if len(response.Records) != len(mutations) {
		return PlainPullResponse{}, errors.New("server returned an incomplete mutation result")
	}
	plain := make([]PlainRecord, 0, len(response.Records))
	for index, record := range response.Records {
		mutation := mutations[index]
		expectedRevision := opaque[index].ExpectedRevision + 1
		if record.Kind != mutation.Kind || record.Key != mutation.Key ||
			record.Revision != expectedRevision || record.Deleted != mutation.Deleted ||
			record.DeviceID != client.state.DeviceID || record.KeyID != client.state.ActiveKeyID {
			return PlainPullResponse{}, errors.New("server mutation result metadata does not match the request")
		}
		payload, err := decryptClientPayload(activeKey, record)
		if err != nil {
			return PlainPullResponse{}, err
		}
		if !bytes.Equal(payload, mutation.Payload) {
			return PlainPullResponse{}, errors.New("server mutation result payload does not match the request")
		}
		plain = append(plain, plainRecord(record, payload))
	}
	for _, record := range response.Records {
		client.state.Revisions[recordIdentity(record.Kind, record.Key)] = record.Revision
	}
	if err := client.state.Save(); err != nil {
		return PlainPullResponse{}, fmt.Errorf("persist accepted revisions: %w", err)
	}
	return PlainPullResponse{Records: plain, NextSeq: response.NextSeq}, nil
}

func (client *Client) Pull(ctx context.Context, kinds []string) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.pullAt(ctx, "/v2/records/pull", client.state.Sequence, kinds)
}

func (client *Client) Latest(ctx context.Context, kinds []string) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.pullAt(ctx, "/v2/records/latest", 0, kinds)
}

func (client *Client) pullAt(ctx context.Context, path string, since Counter, kinds []string) (PlainPullResponse, error) {
	var response PullResponse
	if err := client.doJSON(ctx, http.MethodGet, recordsPath(path, since, kinds), nil, &response); err != nil {
		return PlainPullResponse{}, err
	}
	plain := make([]PlainRecord, 0, len(response.Records))
	for _, record := range response.Records {
		key, err := client.state.decodedKey(record.KeyID)
		if err != nil {
			return PlainPullResponse{}, err
		}
		payload, err := decryptClientPayload(key, record)
		if err != nil {
			return PlainPullResponse{}, err
		}
		plain = append(plain, plainRecord(record, payload))
	}
	return PlainPullResponse{Records: plain, NextSeq: response.NextSeq}, nil
}

// AcknowledgeApplied advances durable client state only after the browser bridge
// has written every returned record and read it back from the browser store.
func (client *Client) AcknowledgeApplied(response PlainPullResponse) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if response.NextSeq < client.state.Sequence {
		return errors.New("cannot move the durable sequence backwards")
	}
	for _, record := range response.Records {
		if record.Seq > response.NextSeq {
			return errors.New("record sequence exceeds response cursor")
		}
		identity := recordIdentity(record.Kind, record.Key)
		current := client.state.Revisions[identity]
		if record.Revision < current {
			return fmt.Errorf("remote revision regressed for %s/%s", record.Kind, record.Key)
		}
		client.state.Revisions[identity] = record.Revision
	}
	client.state.Sequence = response.NextSeq
	return client.state.Save()
}

// StageContentKey persists new key material before contacting the server. A
// failed request or crash is resumable and leaves the old epoch write-active.
func (client *Client) StageContentKey(ctx context.Context) (string, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Role != RoleSeed || client.state.DeviceID != "d" {
		return "", errors.New("only d may stage content keys")
	}
	if client.state.StagedKeyID == "" {
		newKeyID, encodedKey, err := client.state.prepareKeyRotation()
		if err != nil {
			return "", err
		}
		if err := client.state.stageKey(newKeyID, encodedKey); err != nil {
			return "", err
		}
	}
	var response KeyTransitionResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/keys/stage", KeyTransitionRequest{
		ExpectedKeyID: client.state.ActiveKeyID, NewKeyID: client.state.StagedKeyID,
	}, &response); err != nil {
		return "", err
	}
	if response.ActiveKeyID != client.state.ActiveKeyID || response.StagedKeyID != client.state.StagedKeyID {
		return "", errors.New("server returned the wrong staged key status")
	}
	return client.state.StagedKeyID, nil
}

func (client *Client) AcknowledgeStagedKey(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.StagedKeyID == "" || client.state.Keys[client.state.StagedKeyID] == "" {
		return errors.New("client has no staged content key")
	}
	return client.doJSON(ctx, http.MethodPost, "/v2/keys/ack-install", KeyAcknowledgementRequest{KeyID: client.state.StagedKeyID}, nil)
}

func (client *Client) ActivateStagedKey(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Role != RoleSeed || client.state.StagedKeyID == "" {
		return errors.New("only d with a staged key may activate")
	}
	var response KeyTransitionResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/keys/activate", KeyTransitionRequest{
		ExpectedKeyID: client.state.ActiveKeyID, NewKeyID: client.state.StagedKeyID,
	}, &response); err != nil {
		return err
	}
	if response.ActiveKeyID != client.state.StagedKeyID || response.RetiringKeyID != client.state.ActiveKeyID {
		return errors.New("server returned the wrong activated key status")
	}
	return client.state.activateStagedKey()
}

// AdoptServerKeyStatus lets an active join atomically switch only after d has
// activated a key it already installed. The server keeps the retiring epoch
// readable but rejects writes under it, so a failed local save is recovered by
// rerunning this adoption before browser publication resumes.
func (client *Client) AdoptServerKeyStatus(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	var response KeyTransitionResponse
	if err := client.doJSON(ctx, http.MethodGet, "/v2/keys/status", nil, &response); err != nil {
		return err
	}
	if response.ActiveKeyID == client.state.ActiveKeyID {
		if client.state.RetiringKeyID != "" && response.RetiringKeyID == "" {
			return client.state.retireOldKey()
		}
		return nil
	}
	if response.ActiveKeyID != client.state.StagedKeyID || response.RetiringKeyID != client.state.ActiveKeyID {
		return errors.New("server key status cannot be safely adopted")
	}
	return client.state.activateStagedKey()
}

// RekeyAllLatest CAS-rewrites every live record and tombstone under the active
// epoch. It requires a previously browser-acknowledged latest baseline and
// retains the old key until every active device acknowledges and d retires it.
func (client *Client) RekeyAllLatest(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Role != RoleSeed || client.state.DeviceID != "d" || client.state.Phase != PhaseActive {
		return errors.New("only active d may run the content rekey pass")
	}
	latest, err := client.pullAt(ctx, "/v2/records/latest", 0, nil)
	if err != nil {
		return err
	}
	mutations := make([]PlainMutation, 0, len(latest.Records))
	for _, record := range latest.Records {
		if client.state.revision(record.Kind, record.Key) != record.Revision {
			return fmt.Errorf("%s/%s is not at a browser-verified baseline; pull and acknowledge it before rekey", record.Kind, record.Key)
		}
		if record.KeyID != client.state.ActiveKeyID {
			mutations = append(mutations, PlainMutation{
				Kind: record.Kind, Key: record.Key, Deleted: record.Deleted, Payload: record.Payload,
			})
		}
	}
	if _, err := client.pushLocked(ctx, mutations); err != nil {
		return err
	}
	verified, err := client.pullAt(ctx, "/v2/records/latest", 0, nil)
	if err != nil {
		return err
	}
	for _, record := range verified.Records {
		if record.KeyID != client.state.ActiveKeyID {
			return fmt.Errorf("post-rekey inventory retains old key id %q", record.KeyID)
		}
		client.state.Revisions[recordIdentity(record.Kind, record.Key)] = record.Revision
	}
	client.state.Sequence = verified.NextSeq
	if err := client.state.Save(); err != nil {
		return err
	}
	return client.doJSON(ctx, http.MethodPost, "/v2/keys/ack-rekey", KeyAcknowledgementRequest{
		KeyID: client.state.ActiveKeyID, AcknowledgedSeq: verified.NextSeq,
	}, nil)
}

// AcknowledgeActiveRekey is used by da/oneplus after pulling the CAS rekey,
// applying it, and verifying their browser contents at the returned cursor.
func (client *Client) AcknowledgeActiveRekey(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	latest, err := client.pullAt(ctx, "/v2/records/latest", 0, nil)
	if err != nil {
		return err
	}
	for _, record := range latest.Records {
		if record.KeyID != client.state.ActiveKeyID {
			return errors.New("latest inventory still uses a retiring key")
		}
	}
	if client.state.Sequence != latest.NextSeq {
		return errors.New("browser-verified cursor is not at latest rekey inventory")
	}
	return client.doJSON(ctx, http.MethodPost, "/v2/keys/ack-rekey", KeyAcknowledgementRequest{KeyID: client.state.ActiveKeyID, AcknowledgedSeq: latest.NextSeq}, nil)
}

func (client *Client) RetireContentKey(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Role != RoleSeed || client.state.RetiringKeyID == "" {
		return errors.New("only d may retire the old key")
	}
	var response KeyTransitionResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/keys/retire", KeyRetirementRequest{ActiveKeyID: client.state.ActiveKeyID, RetiringKeyID: client.state.RetiringKeyID}, &response); err != nil {
		return err
	}
	if response.ActiveKeyID != client.state.ActiveKeyID || response.RetiringKeyID != "" {
		return errors.New("server did not retire old key")
	}
	return client.state.retireOldKey()
}

// StageCredential sends only a client-computed SHA-256 hash. The new plaintext
// credential remains on the device and overlaps with the old credential.
func (client *Client) StageCredential(ctx context.Context, newToken string) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if err := validateToken(newToken); err != nil {
		return err
	}
	return client.doJSON(ctx, http.MethodPost, "/v2/credentials/stage",
		CredentialStageRequest{NewTokenSHA256: hashToken(newToken)}, nil)
}

// ConfirmCredential is invoked by a client authenticated with the staged new
// credential. Only then may RetireOldCredential remove the overlap.
func (client *Client) ConfirmCredential(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.doJSON(ctx, http.MethodPost, "/v2/credentials/confirm", struct{}{}, nil)
}

func (client *Client) RetireOldCredential(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.doJSON(ctx, http.MethodPost, "/v2/credentials/retire", struct{}{}, nil)
}

// CompleteEnrollment is called only after AcknowledgeApplied has durably
// recorded a browser-verified initial inventory at the current server cursor.
func (client *Client) CompleteEnrollment(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Role != RoleJoin {
		return errors.New("only join devices complete enrollment")
	}
	if client.state.Phase == PhaseActive {
		return nil
	}
	var response EnrollmentCompleteResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/enrollment/complete",
		EnrollmentCompleteRequest{AcknowledgedSeq: client.state.Sequence}, &response); err != nil {
		return err
	}
	if response.Phase != PhaseActive {
		return errors.New("server did not activate enrollment")
	}
	client.state.Phase = PhaseActive
	return client.state.Save()
}

func plainRecord(record OpaqueRecord, payload json.RawMessage) PlainRecord {
	return PlainRecord{
		Seq: record.Seq, Kind: record.Kind, Key: record.Key,
		Revision: record.Revision, Deleted: record.Deleted,
		DeviceID: record.DeviceID, KeyID: record.KeyID, Payload: payload,
	}
}

func recordsPath(path string, since Counter, kinds []string) string {
	query := url.Values{}
	if since > 0 {
		query.Set("since", strconv.FormatInt(int64(since), 10))
	}
	for _, kind := range kinds {
		if strings.TrimSpace(kind) != "" {
			query.Add("kind", kind)
		}
	}
	if encoded := query.Encode(); encoded != "" {
		return path + "?" + encoded
	}
	return path
}

func (client *Client) doJSON(ctx context.Context, method, path string, body any, out any) error {
	var requestBody *bytes.Reader
	if body == nil {
		requestBody = bytes.NewReader(nil)
	} else {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		requestBody = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, client.baseURL+path, requestBody)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := client.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var wire struct {
			Code            string  `json:"code"`
			Error           string  `json:"error"`
			Kind            Kind    `json:"kind"`
			Key             string  `json:"key"`
			CurrentRevision Counter `json:"current_revision"`
		}
		if err := json.NewDecoder(response.Body).Decode(&wire); err != nil {
			return &ProtocolError{StatusCode: response.StatusCode, Message: response.Status}
		}
		return &ProtocolError{
			StatusCode: response.StatusCode, Code: wire.Code, Message: wire.Error,
			Kind: wire.Kind, Key: wire.Key, CurrentRevision: wire.CurrentRevision,
		}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(response.Body).Decode(out)
}
