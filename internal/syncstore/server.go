package syncstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

const maxRequestBytes = 16 * 1024 * 1024

var errDeviceAuthorizationChanged = errors.New(
	"device authorization changed before commit")

func NewHandler(store *Store, registry *DeviceRegistry) http.Handler {
	mux := http.NewServeMux()
	server := server{store: store, registry: registry}
	mux.HandleFunc("/v2/health", server.health)
	mux.HandleFunc(
		"/v2/records/push", server.withScope(ScopePush, server.push))
	mux.HandleFunc(
		"/v2/records/pull", server.withScope(ScopePull, server.pull))
	mux.HandleFunc(
		"/v2/records/latest", server.withScope(ScopePull, server.latest))
	mux.HandleFunc("/v2/credentials/stage",
		server.withScope(ScopePull, server.stageCredential))
	mux.HandleFunc("/v2/credentials/confirm",
		server.withScope(ScopePull, server.confirmCredential))
	mux.HandleFunc("/v2/credentials/retire",
		server.withScope(ScopePull, server.retireCredential))
	mux.HandleFunc("/v2/enrollment/complete",
		server.withScope(ScopePull, server.completeEnrollment))
	return mux
}

type server struct {
	store    *Store
	registry *DeviceRegistry
}

func (server server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (server server) withScope(scope DeviceScope,
	next func(http.ResponseWriter, *http.Request, DevicePrincipal),
) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if server.registry == nil {
			writeError(w, http.StatusInternalServerError,
				"server_misconfigured",
				errors.New("device registry is not configured"))
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "unauthorized",
				errors.New("missing bearer credential"))
			return
		}
		principal, err := server.registry.Authenticate(
			strings.TrimPrefix(auth, "Bearer "))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", err)
			return
		}
		if !principal.Allows(scope) {
			writeError(w, http.StatusForbidden, "scope_denied",
				fmt.Errorf("device %q lacks %s scope",
					principal.ID, scope))
			return
		}
		next(w, r, principal)
	}
}

func (server server) push(
	w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	defer r.Body.Close()
	var request PushRequest
	if err := decodeRequestBody(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request",
			fmt.Errorf("decode request: %w", err))
		return
	}
	for _, mutation := range request.Mutations {
		if mutation.Kind != KindPassword {
			writeError(w, http.StatusBadRequest, "invalid_mutation",
				errors.New("only password records can be synchronized"))
			return
		}
	}
	response, err := server.registry.PutAuthorized(
		server.store, principal, request.Mutations)
	if err != nil {
		if errors.Is(err, errDeviceAuthorizationChanged) {
			writeError(w, http.StatusUnauthorized, "unauthorized", err)
			return
		}
		var conflict *ConflictError
		if errors.As(err, &conflict) {
			writeJSON(w, http.StatusConflict, struct {
				Code            string  `json:"code"`
				Error           string  `json:"error"`
				Kind            Kind    `json:"kind"`
				Key             string  `json:"key"`
				CurrentRevision Counter `json:"current_revision"`
			}{
				"revision_conflict", conflict.Error(), conflict.Kind,
				conflict.Key, conflict.CurrentRevision,
			})
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_mutation", err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (server server) pull(
	w http.ResponseWriter, r *http.Request, _ DevicePrincipal) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	since, cursor, limit, kinds, err := parsePageQuery(r, pullPageMode)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	kinds, err = passwordKindsOnly(kinds)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	response, err := server.store.PullPage(since, cursor, limit, kinds)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_page", err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (server server) latest(
	w http.ResponseWriter, r *http.Request, _ DevicePrincipal) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	_, cursor, limit, kinds, err := parsePageQuery(r, latestPageMode)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	kinds, err = passwordKindsOnly(kinds)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	response, err := server.store.LatestPage(cursor, limit, kinds)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_page", err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func passwordKindsOnly(kinds map[Kind]struct{}) (map[Kind]struct{}, error) {
	if len(kinds) == 0 {
		return map[Kind]struct{}{KindPassword: {}}, nil
	}
	if len(kinds) != 1 {
		return nil, errors.New("only password records can be synchronized")
	}
	if _, ok := kinds[KindPassword]; !ok {
		return nil, errors.New("only password records can be synchronized")
	}
	return kinds, nil
}

func (server server) stageCredential(
	w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	var request CredentialStageRequest
	if !decodePost(w, r, &request) {
		return
	}
	if err := server.registry.StageCredentialHash(
		principal.ID, request.NewTokenSHA256); err != nil {
		writeError(
			w, http.StatusConflict, "credential_stage_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"staged": true})
}

func (server server) confirmCredential(
	w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	if err := server.registry.ConfirmCredential(
		principal.ID, principal.CredentialHash); err != nil {
		writeError(
			w, http.StatusConflict, "credential_confirm_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (server server) retireCredential(
	w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	if err := server.registry.RetireOldCredentials(
		principal.ID, principal.CredentialHash); err != nil {
		writeError(
			w, http.StatusConflict, "credential_retire_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"retired": true})
}

func decodePost(w http.ResponseWriter, r *http.Request, value any) bool {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return false
	}
	defer r.Body.Close()
	if err := decodeRequestBody(w, r, value); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err)
		return false
	}
	return true
}

func (server server) completeEnrollment(
	w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed",
			errors.New("method not allowed"))
		return
	}
	if principal.Role != RoleJoin {
		writeError(w, http.StatusForbidden, "scope_denied",
			errors.New("seed device does not use join enrollment"))
		return
	}
	defer r.Body.Close()
	var request EnrollmentCompleteRequest
	if err := decodeRequestBody(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err)
		return
	}
	current, err := server.registry.PromoteAtCursor(
		server.store, principal.ID, request.AcknowledgedSeq)
	if err != nil && request.AcknowledgedSeq != current {
		writeError(
			w, http.StatusConflict, "enrollment_cursor_conflict", err)
		return
	}
	if err != nil {
		writeError(w, http.StatusConflict, "enrollment_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK,
		EnrollmentCompleteResponse{Phase: PhaseActive})
}

func decodeRequestBody(
	w http.ResponseWriter, r *http.Request, value any) error {
	decoder := json.NewDecoder(
		http.MaxBytesReader(w, r.Body, maxRequestBytes))
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

func parsePageQuery(r *http.Request, mode pageMode,
) (Counter, string, int, map[Kind]struct{}, error) {
	query := r.URL.Query()
	for key := range query {
		if key != "since" && key != "cursor" &&
			key != "limit" && key != "kind" {
			return 0, "", 0, nil,
				fmt.Errorf("unknown query parameter %q", key)
		}
	}
	if len(query["limit"]) != 1 {
		return 0, "", 0, nil,
			errors.New("limit must appear exactly once")
	}
	limit, err := parsePageLimit(query["limit"][0])
	if err != nil {
		return 0, "", 0, nil, err
	}
	if len(query["since"]) > 1 || len(query["cursor"]) > 1 {
		return 0, "", 0, nil,
			errors.New("since and cursor may appear at most once")
	}
	cursor := ""
	if len(query["cursor"]) == 1 {
		cursor = query["cursor"][0]
		if cursor == "" {
			return 0, "", 0, nil, errors.New("cursor cannot be empty")
		}
		if len(query["since"]) != 0 {
			return 0, "", 0, nil,
				errors.New(
					"continuation cursor and since are mutually exclusive")
		}
	}
	if mode == pullPageMode && cursor == "" && len(query["since"]) != 1 {
		return 0, "", 0, nil,
			errors.New("initial pull requires since exactly once")
	}
	var since Counter
	if len(query["since"]) == 1 {
		if mode != pullPageMode {
			return 0, "", 0, nil,
				errors.New("since is valid only for pull")
		}
		raw := query["since"][0]
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < 0 ||
			strconv.FormatInt(value, 10) != raw {
			return 0, "", 0, nil,
				errors.New(
					"since must be a canonical non-negative int64")
		}
		since = Counter(value)
	}
	kinds, err := ParseKinds(query["kind"])
	if err != nil {
		return 0, "", 0, nil, err
	}
	return since, cursor, limit, kinds, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code string, err error) {
	writeJSON(w, status,
		map[string]string{"code": code, "error": err.Error()})
}
