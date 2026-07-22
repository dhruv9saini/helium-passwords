package syncstore

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const (
	pageProtocolVersion  = 1
	maxPageRecords       = 256
	maxPageResponseBytes = 4 * 1024 * 1024
)

type pageMode string

const (
	pullPageMode   pageMode = "pull"
	latestPageMode pageMode = "latest"
)

type pageCursor struct {
	Version  int      `json:"version"`
	Mode     pageMode `json:"mode"`
	Snapshot Counter  `json:"snapshot"`
	Scan     Counter  `json:"scan"`
	Kinds    string   `json:"kinds"`
}

func (store *Store) PullPage(since Counter, cursor string, limit int, kinds map[Kind]struct{}) (PullResponse, error) {
	return store.page(pullPageMode, since, cursor, limit, kinds)
}

func (store *Store) LatestPage(cursor string, limit int, kinds map[Kind]struct{}) (PullResponse, error) {
	return store.page(latestPageMode, 0, cursor, limit, kinds)
}

func (store *Store) page(mode pageMode, since Counter, encodedCursor string, limit int, kinds map[Kind]struct{}) (PullResponse, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	if limit < 1 || limit > maxPageRecords {
		return PullResponse{}, fmt.Errorf("limit must be between 1 and %d", maxPageRecords)
	}
	snapshot := store.cursorLocked()
	scan := since
	if encodedCursor != "" {
		cursor, err := decodePageCursor(encodedCursor, mode, kinds)
		if err != nil {
			return PullResponse{}, err
		}
		snapshot = cursor.Snapshot
		scan = cursor.Scan
	}
	if scan < 0 || snapshot < scan || snapshot > store.cursorLocked() {
		return PullResponse{}, errors.New("page cursor is outside the available journal snapshot")
	}

	latest := map[string]Counter(nil)
	if mode == latestPageMode {
		latest = make(map[string]Counter)
		for _, record := range store.records {
			if record.Seq > snapshot {
				break
			}
			if record.matches(kinds) {
				latest[recordIdentity(record.Kind, record.Key)] = record.Seq
			}
		}
	}

	records := make([]OpaqueRecord, 0, limit)
	for _, record := range store.records {
		if record.Seq <= scan {
			continue
		}
		if record.Seq > snapshot {
			break
		}
		include := record.matches(kinds)
		if include && mode == latestPageMode {
			include = latest[recordIdentity(record.Kind, record.Key)] == record.Seq
		}
		if !include {
			scan = record.Seq
			continue
		}
		if len(records) == limit {
			break
		}
		trial := append(records, record)
		trialCursor := ""
		if record.Seq < snapshot {
			trialCursor = encodePageCursor(pageCursor{
				Version: pageProtocolVersion, Mode: mode, Snapshot: snapshot,
				Scan: record.Seq, Kinds: canonicalKinds(kinds),
			})
		}
		if encodedPageSize(trial, trialCursor, snapshot) > maxPageResponseBytes {
			if len(records) == 0 {
				return PullResponse{}, errors.New("one record cannot fit in a response page")
			}
			break
		}
		records = trial
		scan = record.Seq
	}

	nextCursor := ""
	if scan < snapshot {
		nextCursor = encodePageCursor(pageCursor{
			Version: pageProtocolVersion, Mode: mode, Snapshot: snapshot,
			Scan: scan, Kinds: canonicalKinds(kinds),
		})
	}
	response := PullResponse{
		PageVersion: pageProtocolVersion, PageCursor: nextCursor,
		Records: records, NextSeq: snapshot,
	}
	if raw, err := json.Marshal(response); err != nil {
		return PullResponse{}, err
	} else if len(raw) > maxPageResponseBytes {
		return PullResponse{}, errors.New("response page exceeds encoded byte budget")
	}
	return response, nil
}

func encodedPageSize(records []OpaqueRecord, cursor string, snapshot Counter) int {
	raw, err := json.Marshal(PullResponse{
		PageVersion: pageProtocolVersion, PageCursor: cursor,
		Records: records, NextSeq: snapshot,
	})
	if err != nil {
		return maxPageResponseBytes + 1
	}
	return len(raw)
}

func encodePageCursor(cursor pageCursor) string {
	raw, err := json.Marshal(cursor)
	if err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodePageCursor(encoded string, mode pageMode, kinds map[Kind]struct{}) (pageCursor, error) {
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return pageCursor{}, errors.New("page cursor is not valid base64url")
	}
	var cursor pageCursor
	if err := strictDecode(raw, &cursor); err != nil {
		return pageCursor{}, fmt.Errorf("decode page cursor: %w", err)
	}
	if cursor.Version != pageProtocolVersion || cursor.Mode != mode || cursor.Kinds != canonicalKinds(kinds) {
		return pageCursor{}, errors.New("page cursor does not match this request")
	}
	if cursor.Snapshot < 0 || cursor.Scan < 0 || cursor.Scan >= cursor.Snapshot {
		return pageCursor{}, errors.New("page cursor has invalid sequence bounds")
	}
	if encodePageCursor(cursor) != encoded {
		return pageCursor{}, errors.New("page cursor is not canonically encoded")
	}
	return cursor, nil
}

func canonicalKinds(kinds map[Kind]struct{}) string {
	if len(kinds) == 0 {
		return "*"
	}
	values := make([]string, 0, len(kinds))
	for kind := range kinds {
		values = append(values, string(kind))
	}
	sort.Strings(values)
	return strings.Join(values, ",")
}

func parsePageLimit(raw string) (int, error) {
	if raw == "" {
		return 0, errors.New("limit is required")
	}
	limit, err := strconv.Atoi(raw)
	if err != nil || strconv.Itoa(limit) != raw || limit < 1 || limit > maxPageRecords {
		return 0, fmt.Errorf("limit must be a canonical integer between 1 and %d", maxPageRecords)
	}
	return limit, nil
}
