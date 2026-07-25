package syncstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	clientPageRecords      = 128
	maxClientResponseBytes = 5 * 1024 * 1024
	maxClientPullPages     = 512
	maxClientPullRecords   = clientPageRecords * maxClientPullPages
	maxClientPullBytes     = 128 * 1024 * 1024
)

var tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")

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
		return fmt.Sprintf("%s: %s (current revision %d)",
			http.StatusText(err.StatusCode), err.Message, err.CurrentRevision)
	}
	return fmt.Sprintf("%s: %s", http.StatusText(err.StatusCode), err.Message)
}

func NewClient(baseURL, token, statePath string) (*Client, error) {
	parsedURL, err := url.Parse(baseURL)
	if err != nil || parsedURL.Scheme != "http" || parsedURL.Host == "" ||
		parsedURL.User != nil || parsedURL.RawQuery != "" ||
		parsedURL.Fragment != "" ||
		(parsedURL.Path != "" && parsedURL.Path != "/") {
		return nil, errors.New(
			"base URL must be an HTTP origin without credentials, query, or path")
	}
	address, err := netip.ParseAddr(parsedURL.Hostname())
	if err != nil || !(address.IsLoopback() ||
		(address.Is4() && tailnetIPv4.Contains(address))) {
		return nil, errors.New(
			"base URL must use an exact loopback or Tailscale IPv4 address")
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

func (client *Client) Push(
	ctx context.Context, mutations []PlainMutation) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(mutations) == 0 {
		return PlainPullResponse{
			Records: []PlainRecord{}, NextSeq: client.state.Sequence,
		}, nil
	}
	if client.state.Phase != PhaseActive {
		return PlainPullResponse{}, errors.New(
			"pending join device cannot publish before verified enrollment")
	}
	wire := make([]Mutation, 0, len(mutations))
	seen := make(map[string]struct{}, len(mutations))
	for _, mutation := range mutations {
		identity := recordIdentity(mutation.Kind, mutation.Key)
		if _, duplicate := seen[identity]; duplicate {
			return PlainPullResponse{}, fmt.Errorf(
				"duplicate mutation for %s/%s", mutation.Kind, mutation.Key)
		}
		seen[identity] = struct{}{}
		item := Mutation{
			Kind: mutation.Kind, Key: mutation.Key,
			ExpectedRevision: client.state.revision(
				mutation.Kind, mutation.Key),
			Deleted: mutation.Deleted,
			Payload: append(json.RawMessage(nil), mutation.Payload...),
		}
		if err := item.validate(); err != nil {
			return PlainPullResponse{}, err
		}
		wire = append(wire, item)
	}
	var response PushResponse
	if err := client.doJSON(ctx, http.MethodPost, "/v2/records/push",
		PushRequest{Mutations: wire}, &response); err != nil {
		return PlainPullResponse{}, err
	}
	if len(response.Records) != len(mutations) {
		return PlainPullResponse{}, errors.New(
			"server returned an incomplete mutation result")
	}
	plain := make([]PlainRecord, 0, len(response.Records))
	for index, record := range response.Records {
		if err := record.validate(); err != nil {
			return PlainPullResponse{}, fmt.Errorf(
				"server returned an invalid record: %w", err)
		}
		mutation := mutations[index]
		expectedRevision := wire[index].ExpectedRevision + 1
		if record.Kind != mutation.Kind || record.Key != mutation.Key ||
			record.Revision != expectedRevision ||
			record.Deleted != mutation.Deleted ||
			record.DeviceID != client.state.DeviceID ||
			!bytes.Equal(record.Payload, mutation.Payload) {
			return PlainPullResponse{}, errors.New(
				"server mutation result does not match the request")
		}
		plain = append(plain, plainRecord(record))
		client.state.Revisions[recordIdentity(record.Kind, record.Key)] = record.Revision
	}
	if err := client.state.Save(); err != nil {
		return PlainPullResponse{}, fmt.Errorf(
			"persist accepted revisions: %w", err)
	}
	return PlainPullResponse{
		Records: plain, NextSeq: response.NextSeq,
	}, nil
}

func (client *Client) Pull(
	ctx context.Context, kinds []string) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.pullAt(
		ctx, "/v2/records/pull", client.state.Sequence, kinds)
}

func (client *Client) Latest(
	ctx context.Context, kinds []string) (PlainPullResponse, error) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.pullAt(ctx, "/v2/records/latest", 0, kinds)
}

func (client *Client) pullAt(ctx context.Context, path string,
	since Counter, kinds []string) (PlainPullResponse, error) {
	var records []Record
	var snapshot Counter
	var previousSeq Counter
	totalBytes := 0
	cursor := ""
	seenCursors := make(map[string]struct{})
	for page := 0; page < maxClientPullPages; page++ {
		var response PullResponse
		requestSince := Counter(0)
		if page == 0 {
			requestSince = since
		}
		if err := client.doJSON(ctx, http.MethodGet,
			recordsPath(path, requestSince, cursor, kinds),
			nil, &response); err != nil {
			return PlainPullResponse{}, err
		}
		if response.PageVersion != pageProtocolVersion {
			return PlainPullResponse{}, fmt.Errorf(
				"unsupported page version %d", response.PageVersion)
		}
		if len(response.Records) > clientPageRecords {
			return PlainPullResponse{}, errors.New(
				"server exceeded the requested page record budget")
		}
		totalBytes += encodedPageSize(
			response.Records, response.PageCursor, response.NextSeq)
		if totalBytes > maxClientPullBytes {
			return PlainPullResponse{}, errors.New(
				"pull exceeds the aggregate byte budget")
		}
		if page == 0 {
			snapshot = response.NextSeq
			if snapshot < since {
				return PlainPullResponse{}, errors.New(
					"server page snapshot precedes the requested sequence")
			}
		} else if response.NextSeq != snapshot {
			return PlainPullResponse{}, errors.New(
				"server changed the page snapshot during a pull")
		}
		for _, record := range response.Records {
			if err := record.validate(); err != nil {
				return PlainPullResponse{}, fmt.Errorf(
					"server returned an invalid record: %w", err)
			}
			if record.Seq <= previousSeq || record.Seq > snapshot ||
				(path == "/v2/records/pull" && record.Seq <= since) {
				return PlainPullResponse{}, errors.New(
					"server returned records outside strict page sequence order")
			}
			previousSeq = record.Seq
			records = append(records, record)
			if len(records) > maxClientPullRecords {
				return PlainPullResponse{}, errors.New(
					"pull exceeds the aggregate record budget")
			}
		}
		if response.PageCursor == "" {
			break
		}
		if _, duplicate := seenCursors[response.PageCursor]; duplicate {
			return PlainPullResponse{}, errors.New(
				"server repeated a page cursor")
		}
		seenCursors[response.PageCursor] = struct{}{}
		cursor = response.PageCursor
		if page == maxClientPullPages-1 {
			return PlainPullResponse{}, errors.New(
				"pull exceeds the page-count budget")
		}
	}

	plain := make([]PlainRecord, 0, len(records))
	for _, record := range records {
		plain = append(plain, plainRecord(record))
	}
	return PlainPullResponse{Records: plain, NextSeq: snapshot}, nil
}

// AcknowledgeApplied advances durable client state only after the browser has
// applied and read back every returned record.
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
			return fmt.Errorf(
				"remote revision regressed for %s/%s",
				record.Kind, record.Key)
		}
		client.state.Revisions[identity] = record.Revision
	}
	client.state.Sequence = response.NextSeq
	return client.state.Save()
}

func (client *Client) StageCredential(
	ctx context.Context, newToken string) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	if err := validateToken(newToken); err != nil {
		return err
	}
	return client.doJSON(ctx, http.MethodPost, "/v2/credentials/stage",
		CredentialStageRequest{NewTokenSHA256: hashToken(newToken)}, nil)
}

func (client *Client) ConfirmCredential(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.doJSON(
		ctx, http.MethodPost, "/v2/credentials/confirm", struct{}{}, nil)
}

func (client *Client) RetireOldCredential(ctx context.Context) error {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.doJSON(
		ctx, http.MethodPost, "/v2/credentials/retire", struct{}{}, nil)
}

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
	if err := client.doJSON(
		ctx, http.MethodPost, "/v2/enrollment/complete",
		EnrollmentCompleteRequest{
			AcknowledgedSeq: client.state.Sequence,
		}, &response); err != nil {
		return err
	}
	if response.Phase != PhaseActive {
		return errors.New("server did not activate enrollment")
	}
	client.state.Phase = PhaseActive
	return client.state.Save()
}

func plainRecord(record Record) PlainRecord {
	return PlainRecord{
		Seq: record.Seq, Kind: record.Kind, Key: record.Key,
		Revision: record.Revision, Deleted: record.Deleted,
		DeviceID: record.DeviceID,
		Payload:  append(json.RawMessage(nil), record.Payload...),
	}
}

func recordsPath(
	path string, since Counter, cursor string, kinds []string) string {
	query := url.Values{}
	query.Set("limit", strconv.Itoa(clientPageRecords))
	if cursor != "" {
		query.Set("cursor", cursor)
	}
	if cursor == "" && path == "/v2/records/pull" {
		query.Set("since", strconv.FormatInt(int64(since), 10))
	}
	for _, kind := range kinds {
		if strings.TrimSpace(kind) != "" {
			query.Add("kind", kind)
		}
	}
	return path + "?" + query.Encode()
}

func (client *Client) doJSON(
	ctx context.Context, method, path string, body, out any) error {
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
	request, err := http.NewRequestWithContext(
		ctx, method, client.baseURL+path, requestBody)
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
	raw, readErr := io.ReadAll(
		io.LimitReader(response.Body, maxClientResponseBytes+1))
	if readErr != nil {
		return readErr
	}
	if len(raw) > maxClientResponseBytes {
		return errors.New("server response exceeds the client byte budget")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var wire struct {
			Code            string  `json:"code"`
			Error           string  `json:"error"`
			Kind            Kind    `json:"kind"`
			Key             string  `json:"key"`
			CurrentRevision Counter `json:"current_revision"`
		}
		if err := strictDecode(raw, &wire); err != nil {
			return &ProtocolError{
				StatusCode: response.StatusCode, Message: response.Status,
			}
		}
		return &ProtocolError{
			StatusCode: response.StatusCode, Code: wire.Code,
			Message: wire.Error, Kind: wire.Kind, Key: wire.Key,
			CurrentRevision: wire.CurrentRevision,
		}
	}
	if out == nil {
		return nil
	}
	return strictDecode(raw, out)
}
