// Copyright 2026 The Helium Authors

#include "components/helium_sync/helium_sync_client.h"

#include <algorithm>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/values.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace helium_sync {
namespace {

constexpr char kContentType[] = "application/json";
constexpr int kMaxSyncResponseBytes = 5 * 1024 * 1024;
constexpr size_t kMaxSyncRequestBytes = 4 * 1024 * 1024;
constexpr size_t kRecordsPageSize = 128;
constexpr size_t kMaxRecordsPages = 512;
constexpr size_t kMaxRecordsPerSync = kRecordsPageSize * kMaxRecordsPages;
constexpr size_t kMaxAggregateResponseBytes = 128 * 1024 * 1024;
constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("helium_sync_tailnet_daemon", R"(
      semantics {
        sender: "Helium Tailnet sync client"
        description:
          "Sends authenticated password and cookie records to the configured "
          "Helium sync daemon through the user's Tailscale network."
        trigger:
          "The user has enrolled this Helium profile for private sync."
        data:
          "Password or cookie records and a per-device bearer credential."
        destination: OTHER
        internal {
          contacts { email: "security@imput.net" }
        }
        user_data {
          type: ACCESS_TOKEN
          type: WEB_CONTENT
        }
        last_reviewed: "2026-07-21"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Active only after explicit Helium sync enrollment and daemon "
          "configuration."
        policy_exception_justification:
          "Not implemented as an enterprise policy."
      })");

bool ParseCounter(const base::DictValue &dict, std::string_view name,
                  bool positive, int64_t *out) {
  const std::string *encoded = dict.FindString(name);
  return encoded && base::StringToInt64(*encoded, out) &&
         (positive ? *out > 0 : *out >= 0);
}

std::string RecordsPath(std::string_view path, std::optional<int64_t> since,
                        std::string_view cursor,
                        const std::vector<std::string> &kinds) {
  std::string out(path);
  bool first = true;
  auto append_param = [&](std::string_view key, std::string_view value) {
    out += first ? "?" : "&";
    first = false;
    out += key;
    out += "=";
    out += base::EscapeQueryParamValue(value, true);
  };
  append_param("limit", base::NumberToString(kRecordsPageSize));
  if (since) {
    append_param("since", base::NumberToString(*since));
  }
  if (!cursor.empty()) {
    append_param("cursor", cursor);
  }
  for (const auto &kind : kinds) {
    if (!kind.empty()) {
      append_param("kind", kind);
    }
  }
  return out;
}

} // namespace

struct HeliumSyncClient::PaginationState {
  std::string path;
  std::optional<int64_t> since;
  std::vector<std::string> kinds;
  std::string cursor;
  std::optional<int64_t> next_seq;
  std::vector<Record> records;
  std::vector<std::string> seen_cursors;
  size_t pages = 0;
  size_t aggregate_response_bytes = 0;
};

HeliumSyncClient::HeliumSyncClient(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
    GURL base_url, std::string bearer_token, base::FilePath client_state_path)
    : url_loader_factory_(std::move(url_loader_factory)),
      base_url_(std::move(base_url)), bearer_token_(std::move(bearer_token)),
      client_state_path_(std::move(client_state_path)) {
  if (!LoadClientState(client_state_path_) && state_error_.empty()) {
    state_error_ = "client state is invalid";
  }
}

HeliumSyncClient::~HeliumSyncClient() = default;

void HeliumSyncClient::Push(std::vector<Record> records,
                            RecordsCallback callback) {
  if (records.empty()) {
    std::move(callback).Run(true, RecordsResult(), std::string());
    return;
  }
  if (!state_error_.empty()) {
    std::move(callback).Run(false, RecordsResult(), state_error_);
    return;
  }
  if (state_.phase != "active") {
    std::move(callback).Run(false, RecordsResult(),
                            "pending enrollment may not publish");
    return;
  }
  base::ListValue mutations;
  for (const Record &record : records) {
    base::DictValue mutation;
    std::string error;
    if (!EncodeMutation(record, &mutation, &error)) {
      std::move(callback).Run(false, RecordsResult(), std::move(error));
      return;
    }
    mutations.Append(std::move(mutation));
  }
  base::DictValue body;
  body.Set("mutations", std::move(mutations));
  std::string body_json;
  if (!base::JSONWriter::Write(body, &body_json)) {
    std::move(callback).Run(false, RecordsResult(),
                            "failed to encode push JSON");
    return;
  }
  if (body_json.size() > kMaxSyncRequestBytes) {
    std::move(callback).Run(false, RecordsResult(),
                            "sync request exceeded the byte limit");
    return;
  }
  auto loader = MakeJSONRequest(base_url_.Resolve("/v2/records/push"), "POST",
                                std::move(body_json));
  auto *loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(url_loader_factory_.get(),
                               base::BindOnce(&HeliumSyncClient::OnPushComplete,
                                              weak_factory_.GetWeakPtr(),
                                              loader_ptr, std::move(records),
                                              std::move(callback)),
                               kMaxSyncResponseBytes);
}

void HeliumSyncClient::Pull(int64_t since, std::vector<std::string> kinds,
                            RecordsCallback callback) {
  if (since < 0) {
    std::move(callback).Run(false, RecordsResult(),
                            "pull sequence must be non-negative");
    return;
  }
  if (!state_error_.empty()) {
    std::move(callback).Run(false, RecordsResult(), state_error_);
    return;
  }
  auto pagination = std::make_unique<PaginationState>();
  pagination->path = "/v2/records/pull";
  pagination->since = since;
  pagination->kinds = std::move(kinds);
  FetchRecordsPage(std::move(pagination), std::move(callback));
}

void HeliumSyncClient::Latest(std::vector<std::string> kinds,
                              RecordsCallback callback) {
  if (!state_error_.empty()) {
    std::move(callback).Run(false, RecordsResult(), state_error_);
    return;
  }
  auto pagination = std::make_unique<PaginationState>();
  pagination->path = "/v2/records/latest";
  pagination->kinds = std::move(kinds);
  FetchRecordsPage(std::move(pagination), std::move(callback));
}

bool HeliumSyncClient::AcknowledgeApplied(int64_t next_seq,
                                          std::string *error) {
  if (!error || next_seq < state_.sequence) {
    if (error) {
      *error = "cannot move the verified sync cursor backwards";
    }
    return false;
  }
  if (!PersistStateProgress(next_seq, std::nullopt, error)) {
    return false;
  }
  state_.sequence = next_seq;
  return true;
}

bool HeliumSyncClient::ReloadEnrollmentState(std::string *error) {
  if (!error) {
    return false;
  }
  ClientState previous = state_;
  state_error_.clear();
  if (!LoadClientState(client_state_path_)) {
    *error = state_error_;
    state_ = std::move(previous);
    return false;
  }
  if (state_.device_id != previous.device_id || state_.role != previous.role ||
      state_.sequence < previous.sequence ||
      (previous.phase == "active" && state_.phase != "active")) {
    state_ = std::move(previous);
    state_error_ = "client enrollment state changed unexpectedly";
    *error = state_error_;
    return false;
  }
  return true;
}

void HeliumSyncClient::CompleteEnrollment(int64_t acknowledged_seq,
                                          StatusCallback callback) {
  if (!state_error_.empty()) {
    std::move(callback).Run(false, state_error_);
    return;
  }
  if (state_.role == "seed" || state_.phase == "active") {
    std::move(callback).Run(true, std::string());
    return;
  }
  if (acknowledged_seq != state_.sequence) {
    std::move(callback).Run(false,
                            "enrollment cursor was not durably acknowledged");
    return;
  }
  base::DictValue body;
  body.Set("acknowledged_seq", base::NumberToString(acknowledged_seq));
  std::string body_json;
  if (!base::JSONWriter::Write(body, &body_json)) {
    std::move(callback).Run(false, "failed to encode enrollment completion");
    return;
  }
  auto loader = MakeJSONRequest(base_url_.Resolve("/v2/enrollment/complete"),
                                "POST", std::move(body_json));
  auto *loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&HeliumSyncClient::OnEnrollmentComplete,
                     weak_factory_.GetWeakPtr(), loader_ptr, acknowledged_seq,
                     std::move(callback)),
      64 * 1024);
}

bool HeliumSyncClient::LoadClientState(const base::FilePath &path) {
  if (path.empty()) {
    state_error_ = "client state path is required";
    return false;
  }
  std::string raw;
  if (!base::ReadFileToString(path, &raw)) {
    state_error_ = "client state is missing or unreadable";
    return false;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    state_error_ = "client state is malformed";
    return false;
  }
  const base::DictValue &root = parsed->GetDict();
  const std::string *device_id = root.FindString("device_id");
  const std::string *role = root.FindString("role");
  const std::string *phase = root.FindString("phase");
  const std::string *sequence = root.FindString("sequence");
  int64_t parsed_sequence = -1;
  const base::DictValue *revisions = root.FindDict("revisions");
  if (root.FindInt("version").value_or(0) != 2 || !device_id ||
      device_id->empty() || !role || (*role != "seed" && *role != "join") ||
      !phase || (*phase != "pending" && *phase != "active") || !sequence ||
      !base::StringToInt64(*sequence, &parsed_sequence) ||
      parsed_sequence < 0 || !revisions) {
    state_error_ = "client state has invalid enrollment metadata";
    return false;
  }
  ClientState candidate;
  candidate.device_id = *device_id;
  candidate.role = *role;
  candidate.phase = *phase;
  candidate.sequence = parsed_sequence;
  for (const auto [identity, revision] : *revisions) {
    int64_t parsed_revision = -1;
    if (identity.empty() || !revision.is_string() ||
        !base::StringToInt64(revision.GetString(), &parsed_revision) ||
        parsed_revision < 0) {
      state_error_ = "client revision state is invalid";
      return false;
    }
  }
  if ((candidate.role == "seed" &&
       (candidate.device_id != "d" || candidate.phase != "active")) ||
      (candidate.role == "join" && candidate.device_id == "d")) {
    state_error_ = "client state violates enrollment role invariants";
    return false;
  }
  state_ = std::move(candidate);
  return true;
}

bool HeliumSyncClient::PersistStateProgress(
    int64_t sequence, std::optional<std::string_view> phase,
    std::string *error) {
  std::string raw;
  if (!base::ReadFileToString(client_state_path_, &raw)) {
    *error = "client state disappeared before progress could be persisted";
    return false;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  const std::string *persisted_device =
      parsed && parsed->is_dict() ? parsed->GetDict().FindString("device_id")
                                  : nullptr;
  if (!persisted_device || *persisted_device != state_.device_id) {
    *error = "client state changed identity while sync was running";
    return false;
  }
  base::DictValue &root = parsed->GetDict();
  int64_t persisted_sequence = -1;
  const std::string *encoded_sequence = root.FindString("sequence");
  if (!encoded_sequence ||
      !base::StringToInt64(*encoded_sequence, &persisted_sequence) ||
      persisted_sequence < 0 || sequence < persisted_sequence) {
    *error = "client state cursor would regress";
    return false;
  }
  root.Set("sequence", base::NumberToString(sequence));
  if (phase) {
    root.Set("phase", std::string(*phase));
  }
  if (!base::JSONWriter::Write(*parsed, &raw) ||
      !base::ImportantFileWriter::WriteFileAtomically(client_state_path_, raw,
                                                      "HeliumSync")) {
    *error = "failed to atomically persist client sync progress";
    return false;
  }
  return true;
}

bool HeliumSyncClient::EncodeMutation(const Record &record,
                                      base::DictValue *wire,
                                      std::string *error) const {
  if (!wire || !error || record.expected_revision < 0 || record.kind.empty() ||
      record.key.empty() ||
      record.expected_revision == std::numeric_limits<int64_t>::max()) {
    if (error) {
      *error = "outgoing record metadata is invalid";
    }
    return false;
  }
  std::optional<base::Value> payload =
      base::JSONReader::Read(record.payload_json, base::JSON_PARSE_RFC);
  if (!payload) {
    *error = "outgoing payload is not valid JSON";
    return false;
  }
  wire->Set("kind", record.kind);
  wire->Set("key", record.key);
  wire->Set("expected_revision",
            base::NumberToString(record.expected_revision));
  wire->Set("deleted", record.deleted);
  wire->Set("payload", std::move(*payload));
  return true;
}

std::optional<RecordsResult>
HeliumSyncClient::ParseRecordsObject(const base::DictValue &root,
                                     std::string *error) const {
  const base::ListValue *values = root.FindList("records");
  RecordsResult result;
  if (!values || !ParseCounter(root, "next_seq", false, &result.next_seq)) {
    *error = "sync response lacks an int64 cursor or records list";
    return std::nullopt;
  }
  for (const base::Value &value : *values) {
    if (!value.is_dict()) {
      *error = "sync response contains a non-object record";
      return std::nullopt;
    }
    const base::DictValue &wire = value.GetDict();
    const std::string *kind = wire.FindString("kind");
    const std::string *key = wire.FindString("key");
    const std::string *device_id = wire.FindString("device_id");
    const base::Value *payload = wire.Find("payload");
    std::optional<bool> deleted = wire.FindBool("deleted");
    Record record;
    if (!kind || kind->empty() || !key || key->empty() || !device_id ||
        device_id->empty() || !payload || !deleted ||
        !ParseCounter(wire, "seq", true, &record.seq) ||
        !ParseCounter(wire, "revision", true, &record.revision)) {
      *error = "sync response record metadata is invalid";
      return std::nullopt;
    }
    if (!base::JSONWriter::Write(*payload, &record.payload_json)) {
      *error = "sync response payload could not be serialized";
      return std::nullopt;
    }
    record.expected_revision = record.revision - 1;
    record.kind = *kind;
    record.key = *key;
    record.deleted = *deleted;
    record.device_id = *device_id;
    result.records.push_back(std::move(record));
  }
  return result;
}

std::optional<RecordsResult>
HeliumSyncClient::ParseRecordsResponse(std::string_view body,
                                       std::string *error) const {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    *error = "sync response is not a JSON object";
    return std::nullopt;
  }
  return ParseRecordsObject(parsed->GetDict(), error);
}

std::optional<RecordsResult> HeliumSyncClient::ParseRecordsPageResponse(
    std::string_view body, std::string *page_cursor, std::string *error) const {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    *error = "sync page response is not a JSON object";
    return std::nullopt;
  }
  const base::DictValue &root = parsed->GetDict();
  const std::string *cursor = root.FindString("page_cursor");
  if (root.FindInt("page_version").value_or(0) != 1 || !cursor) {
    *error = "sync page response has invalid pagination metadata";
    return std::nullopt;
  }
  *page_cursor = *cursor;
  return ParseRecordsObject(root, error);
}

void HeliumSyncClient::FetchRecordsPage(
    std::unique_ptr<PaginationState> pagination, RecordsCallback callback) {
  if (pagination->pages >= kMaxRecordsPages) {
    std::move(callback).Run(false, RecordsResult(),
                            "sync response exceeded the page limit");
    return;
  }
  const std::optional<int64_t> since =
      pagination->cursor.empty() ? pagination->since : std::nullopt;
  auto loader = MakeJSONRequest(
      base_url_.Resolve(RecordsPath(pagination->path, since, pagination->cursor,
                                    pagination->kinds)),
      "GET", std::string());
  ++pagination->pages;
  auto *loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&HeliumSyncClient::OnRecordsPageComplete,
                     weak_factory_.GetWeakPtr(), loader_ptr,
                     std::move(pagination), std::move(callback)),
      kMaxSyncResponseBytes);
}

void HeliumSyncClient::OnRecordsPageComplete(
    network::SimpleURLLoader *loader,
    std::unique_ptr<PaginationState> pagination, RecordsCallback callback,
    std::optional<std::string> body) {
  const int net_error = loader->NetError();
  int response_code = 0;
  if (loader->ResponseInfo() && loader->ResponseInfo()->headers) {
    response_code = loader->ResponseInfo()->headers->response_code();
  }
  if (net_error != net::OK || !body || response_code < 200 ||
      response_code >= 300) {
    std::string error =
        "sync HTTP request failed: net=" + base::NumberToString(net_error) +
        " status=" + base::NumberToString(response_code);
    RemoveLoader(loader);
    std::move(callback).Run(false, RecordsResult(), std::move(error));
    return;
  }
  if (body->size() >
      kMaxAggregateResponseBytes - pagination->aggregate_response_bytes) {
    RemoveLoader(loader);
    std::move(callback).Run(false, RecordsResult(),
                            "sync response exceeded the aggregate byte limit");
    return;
  }
  pagination->aggregate_response_bytes += body->size();
  std::string error;
  std::string page_cursor;
  std::optional<RecordsResult> page =
      ParseRecordsPageResponse(*body, &page_cursor, &error);
  RemoveLoader(loader);
  if (!page) {
    std::move(callback).Run(false, RecordsResult(), std::move(error));
    return;
  }
  if (page->records.size() > kRecordsPageSize ||
      page->records.size() > kMaxRecordsPerSync - pagination->records.size()) {
    std::move(callback).Run(false, RecordsResult(),
                            "sync response exceeded the record limit");
    return;
  }
  if (!pagination->next_seq) {
    if (pagination->since && page->next_seq < *pagination->since) {
      std::move(callback).Run(false, RecordsResult(),
                              "sync snapshot cursor precedes pull cursor");
      return;
    }
    pagination->next_seq = page->next_seq;
  } else if (page->next_seq != *pagination->next_seq) {
    std::move(callback).Run(false, RecordsResult(),
                            "sync snapshot cursor changed between pages");
    return;
  }
  int64_t previous_seq =
      pagination->records.empty() ? 0 : pagination->records.back().seq;
  for (Record &record : page->records) {
    if (record.seq <= previous_seq || record.seq > *pagination->next_seq ||
        (pagination->since && record.seq <= *pagination->since)) {
      std::move(callback).Run(false, RecordsResult(),
                              "sync page records are not strictly ordered");
      return;
    }
    previous_seq = record.seq;
    pagination->records.push_back(std::move(record));
  }
  if (page_cursor.empty()) {
    RecordsResult result;
    result.records = std::move(pagination->records);
    result.next_seq = *pagination->next_seq;
    std::move(callback).Run(true, std::move(result), std::string());
    return;
  }
  if (std::find(pagination->seen_cursors.begin(),
                pagination->seen_cursors.end(),
                page_cursor) != pagination->seen_cursors.end()) {
    std::move(callback).Run(false, RecordsResult(),
                            "sync page cursor did not progress");
    return;
  }
  pagination->seen_cursors.push_back(page_cursor);
  pagination->cursor = std::move(page_cursor);
  FetchRecordsPage(std::move(pagination), std::move(callback));
}

void HeliumSyncClient::OnPushComplete(network::SimpleURLLoader *loader,
                                      std::vector<Record> expected,
                                      RecordsCallback callback,
                                      std::optional<std::string> body) {
  const int net_error = loader->NetError();
  int response_code = 0;
  if (loader->ResponseInfo() && loader->ResponseInfo()->headers) {
    response_code = loader->ResponseInfo()->headers->response_code();
  }
  if (net_error != net::OK || !body || response_code < 200 ||
      response_code >= 300) {
    std::string error =
        "sync HTTP request failed: net=" + base::NumberToString(net_error) +
        " status=" + base::NumberToString(response_code);
    RemoveLoader(loader);
    std::move(callback).Run(false, RecordsResult(), std::move(error));
    return;
  }
  std::string error;
  std::optional<RecordsResult> result = ParseRecordsResponse(*body, &error);
  if (!result) {
    RemoveLoader(loader);
    std::move(callback).Run(false, RecordsResult(), std::move(error));
    return;
  }
  if (expected.size() != result->records.size()) {
    RemoveLoader(loader);
    std::move(callback).Run(false, RecordsResult(),
                            "push result record count mismatch");
    return;
  }
  for (size_t i = 0; i < expected.size(); ++i) {
    const Record &request = expected[i];
    const Record &accepted = result->records[i];
    if (accepted.kind != request.kind || accepted.key != request.key ||
        accepted.deleted != request.deleted ||
        accepted.revision != request.expected_revision + 1 ||
        accepted.seq > result->next_seq ||
        accepted.device_id != state_.device_id ||
        accepted.payload_json != request.payload_json) {
      RemoveLoader(loader);
      std::move(callback).Run(false, RecordsResult(),
                              "push result failed exact comparison");
      return;
    }
  }
  RemoveLoader(loader);
  std::move(callback).Run(true, std::move(*result), std::string());
}

void HeliumSyncClient::OnEnrollmentComplete(network::SimpleURLLoader *loader,
                                            int64_t acknowledged_seq,
                                            StatusCallback callback,
                                            std::optional<std::string> body) {
  const int net_error = loader->NetError();
  int response_code = 0;
  if (loader->ResponseInfo() && loader->ResponseInfo()->headers) {
    response_code = loader->ResponseInfo()->headers->response_code();
  }
  if (net_error != net::OK || !body || response_code < 200 ||
      response_code >= 300) {
    RemoveLoader(loader);
    std::move(callback).Run(false, "enrollment completion HTTP request failed");
    return;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(*body, base::JSON_PARSE_RFC);
  const std::string *phase = parsed && parsed->is_dict()
                                 ? parsed->GetDict().FindString("phase")
                                 : nullptr;
  if (!phase || *phase != "active") {
    RemoveLoader(loader);
    std::move(callback).Run(false, "server did not confirm active enrollment");
    return;
  }
  std::string error;
  if (!PersistStateProgress(acknowledged_seq, "active", &error)) {
    RemoveLoader(loader);
    std::move(callback).Run(false, std::move(error));
    return;
  }
  state_.phase = "active";
  state_.sequence = acknowledged_seq;
  RemoveLoader(loader);
  std::move(callback).Run(true, std::string());
}

std::unique_ptr<network::SimpleURLLoader>
HeliumSyncClient::MakeJSONRequest(GURL url, std::string method,
                                  std::string body) {
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = std::move(url);
  request->method = std::move(method);
  request->load_flags = net::LOAD_BYPASS_CACHE | net::LOAD_DISABLE_CACHE;
  request->headers.SetHeader("Authorization", "Bearer " + bearer_token_);
  auto loader =
      network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
  if (!body.empty()) {
    loader->AttachStringForUpload(std::move(body), kContentType);
  }
  return loader;
}

void HeliumSyncClient::RemoveLoader(network::SimpleURLLoader *loader) {
  std::erase_if(loaders_,
                [loader](const auto &owned) { return owned.get() == loader; });
}

} // namespace helium_sync
