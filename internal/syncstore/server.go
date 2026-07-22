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

var errDeviceAuthorizationChanged = errors.New("device authorization changed before commit")

func NewHandler(store *Store, registry *DeviceRegistry) http.Handler {
	mux := http.NewServeMux()
	server := server{store: store, registry: registry}
	mux.HandleFunc("/v2/health", server.health)
	mux.HandleFunc("/v2/records/push", server.withScope(ScopePush, server.push))
	mux.HandleFunc("/v2/records/pull", server.withScope(ScopePull, server.pull))
	mux.HandleFunc("/v2/records/latest", server.withScope(ScopePull, server.latest))
	mux.HandleFunc("/v2/keys/stage", server.withScope(ScopeRotate, server.stageKey))
	mux.HandleFunc("/v2/keys/status", server.withScope(ScopePull, server.keyStatus))
	mux.HandleFunc("/v2/keys/ack-install", server.withScope(ScopePull, server.ackKeyInstall))
	mux.HandleFunc("/v2/keys/activate", server.withScope(ScopeRotate, server.activateKey))
	mux.HandleFunc("/v2/keys/ack-rekey", server.withScope(ScopePull, server.ackRekey))
	mux.HandleFunc("/v2/keys/retire", server.withScope(ScopeRotate, server.retireKey))
	mux.HandleFunc("/v2/credentials/stage", server.withScope(ScopePull, server.stageCredential))
	mux.HandleFunc("/v2/credentials/confirm", server.withScope(ScopePull, server.confirmCredential))
	mux.HandleFunc("/v2/credentials/retire", server.withScope(ScopePull, server.retireCredential))
	mux.HandleFunc("/v2/enrollment/complete", server.withScope(ScopePull, server.completeEnrollment))
	return mux
}

type server struct {
	store    *Store
	registry *DeviceRegistry
}

func (server server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (server server) withScope(scope DeviceScope, next func(http.ResponseWriter, *http.Request, DevicePrincipal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if server.registry == nil {
			writeError(w, http.StatusInternalServerError, "server_misconfigured", errors.New("device registry is not configured"))
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "unauthorized", errors.New("missing bearer credential"))
			return
		}
		principal, err := server.registry.Authenticate(strings.TrimPrefix(auth, "Bearer "))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", err)
			return
		}
		if !principal.Allows(scope) {
			writeError(w, http.StatusForbidden, "scope_denied", fmt.Errorf("device %q lacks %s scope", principal.ID, scope))
			return
		}
		next(w, r, principal)
	}
}

func (server server) push(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	defer r.Body.Close()
	var request PushRequest
	if err := decodeRequestBody(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", fmt.Errorf("decode request: %w", err))
		return
	}
	response, err := server.registry.PutAuthorized(server.store, principal, request.Mutations)
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
			}{"revision_conflict", conflict.Error(), conflict.Kind, conflict.Key, conflict.CurrentRevision})
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_mutation", err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (server server) pull(w http.ResponseWriter, r *http.Request, _ DevicePrincipal) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	since, kinds, err := parseQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	writeJSON(w, http.StatusOK, server.store.Pull(since, kinds))
}

func (server server) latest(w http.ResponseWriter, r *http.Request, _ DevicePrincipal) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	_, kinds, err := parseQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_query", err)
		return
	}
	writeJSON(w, http.StatusOK, server.store.Latest(kinds))
}

func (server server) stageKey(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	if principal.Role != RoleSeed || principal.ID != "d" {
		writeError(w, http.StatusForbidden, "scope_denied", errors.New("only d may rotate content keys"))
		return
	}
	defer r.Body.Close()
	var request KeyTransitionRequest
	if err := decodeRequestBody(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err)
		return
	}
	if err := server.registry.StageKey(request.ExpectedKeyID, request.NewKeyID); err != nil {
		writeError(w, http.StatusConflict, "key_rotation_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, KeyTransitionResponse{ActiveKeyID: request.ExpectedKeyID, StagedKeyID: request.NewKeyID})
}

func (server server) keyStatus(w http.ResponseWriter, r *http.Request, _ DevicePrincipal) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	writeJSON(w, http.StatusOK, server.registry.KeyStatus())
}

func (server server) ackKeyInstall(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	var request KeyAcknowledgementRequest
	if !decodePost(w, r, &request) {
		return
	}
	if err := server.registry.AcknowledgeKeyInstall(principal.ID, request.KeyID); err != nil {
		writeError(w, http.StatusConflict, "key_install_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"acknowledged": true})
}

func (server server) activateKey(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if principal.Role != RoleSeed {
		writeError(w, http.StatusForbidden, "scope_denied", errors.New("only d may activate keys"))
		return
	}
	var request KeyTransitionRequest
	if !decodePost(w, r, &request) {
		return
	}
	if err := server.registry.ActivateStagedKey(request.ExpectedKeyID, request.NewKeyID); err != nil {
		writeError(w, http.StatusConflict, "key_activation_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, KeyTransitionResponse{ActiveKeyID: request.NewKeyID, RetiringKeyID: request.ExpectedKeyID})
}

func (server server) ackRekey(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	var request KeyAcknowledgementRequest
	if !decodePost(w, r, &request) {
		return
	}
	if request.AcknowledgedSeq != server.store.Cursor() {
		writeError(w, http.StatusConflict, "rekey_cursor_conflict", errors.New("rekey acknowledgement cursor is stale"))
		return
	}
	if err := server.registry.AcknowledgeRekey(principal.ID, request.KeyID); err != nil {
		writeError(w, http.StatusConflict, "rekey_ack_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"acknowledged": true})
}

func (server server) retireKey(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if principal.Role != RoleSeed {
		writeError(w, http.StatusForbidden, "scope_denied", errors.New("only d may retire keys"))
		return
	}
	var request KeyRetirementRequest
	if !decodePost(w, r, &request) {
		return
	}
	if err := server.registry.RetireKey(request.ActiveKeyID, request.RetiringKeyID); err != nil {
		writeError(w, http.StatusConflict, "key_retirement_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, KeyTransitionResponse{ActiveKeyID: request.ActiveKeyID})
}

func (server server) stageCredential(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	var request CredentialStageRequest
	if !decodePost(w, r, &request) {
		return
	}
	if err := server.registry.StageCredentialHash(principal.ID, request.NewTokenSHA256); err != nil {
		writeError(w, http.StatusConflict, "credential_stage_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"staged": true})
}

func (server server) confirmCredential(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	if err := server.registry.ConfirmCredential(principal.ID, principal.CredentialHash); err != nil {
		writeError(w, http.StatusConflict, "credential_confirm_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (server server) retireCredential(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	if err := server.registry.RetireOldCredentials(principal.ID, principal.CredentialHash); err != nil {
		writeError(w, http.StatusConflict, "credential_retire_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"retired": true})
}

func decodePost(w http.ResponseWriter, r *http.Request, value any) bool {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return false
	}
	defer r.Body.Close()
	if err := decodeRequestBody(w, r, value); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err)
		return false
	}
	return true
}

func (server server) completeEnrollment(w http.ResponseWriter, r *http.Request, principal DevicePrincipal) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", errors.New("method not allowed"))
		return
	}
	if principal.Role != RoleJoin {
		writeError(w, http.StatusForbidden, "scope_denied", errors.New("seed device does not use join enrollment"))
		return
	}
	defer r.Body.Close()
	var request EnrollmentCompleteRequest
	if err := decodeRequestBody(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err)
		return
	}
	current := server.store.Cursor()
	if request.AcknowledgedSeq != current {
		writeError(w, http.StatusConflict, "enrollment_cursor_conflict",
			fmt.Errorf("acknowledged sequence %d is not current sequence %d", request.AcknowledgedSeq, current))
		return
	}
	if err := server.registry.Promote(principal.ID); err != nil {
		writeError(w, http.StatusConflict, "enrollment_conflict", err)
		return
	}
	writeJSON(w, http.StatusOK, EnrollmentCompleteResponse{Phase: PhaseActive})
}

func decodeRequestBody(w http.ResponseWriter, r *http.Request, value any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBytes))
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

func parseQuery(r *http.Request) (Counter, map[Kind]struct{}, error) {
	query := r.URL.Query()
	var since Counter
	if raw := query.Get("since"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < 0 {
			return 0, nil, errors.New("since must be a non-negative int64")
		}
		since = Counter(value)
	}
	kinds, err := ParseKinds(query["kind"])
	if err != nil {
		return 0, nil, err
	}
	return since, kinds, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code string, err error) {
	writeJSON(w, status, map[string]string{"code": code, "error": err.Error()})
}
