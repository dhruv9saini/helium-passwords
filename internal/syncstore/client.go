package syncstore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Client struct {
	baseURL string
	token   string
	http    *http.Client
}

func NewClient(baseURL, token string) *Client {
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		http:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (client *Client) Push(ctx context.Context, request PushRequest) (PushResponse, error) {
	var response PushResponse
	err := client.doJSON(ctx, http.MethodPost, "/v1/records/push", request, &response)
	return response, err
}

func (client *Client) Pull(ctx context.Context, since int64, kinds []string) (PullResponse, error) {
	var response PullResponse
	err := client.doJSON(ctx, http.MethodGet, client.recordsPath("/v1/records/pull", since, kinds, false), nil, &response)
	return response, err
}

func (client *Client) Latest(ctx context.Context, kinds []string, includeDeleted bool) (PullResponse, error) {
	var response PullResponse
	err := client.doJSON(ctx, http.MethodGet, client.recordsPath("/v1/records/latest", 0, kinds, includeDeleted), nil, &response)
	return response, err
}

func (client *Client) recordsPath(path string, since int64, kinds []string, includeDeleted bool) string {
	query := url.Values{}
	if since > 0 {
		query.Set("since", strconv.FormatInt(since, 10))
	}
	for _, kind := range kinds {
		if strings.TrimSpace(kind) != "" {
			query.Add("kind", kind)
		}
	}
	if includeDeleted {
		query.Set("include_deleted", "true")
	}
	encoded := query.Encode()
	if encoded == "" {
		return path
	}
	return path + "?" + encoded
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
		var errorBody map[string]string
		if err := json.NewDecoder(response.Body).Decode(&errorBody); err == nil && errorBody["error"] != "" {
			return fmt.Errorf("%s: %s", response.Status, errorBody["error"])
		}
		return fmt.Errorf("%s", response.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(response.Body).Decode(out)
}
