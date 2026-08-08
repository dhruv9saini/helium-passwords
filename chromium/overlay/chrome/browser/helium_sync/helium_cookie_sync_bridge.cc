// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"

#include <algorithm>
#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "components/helium_sync/helium_sync_client.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "net/base/schemeful_site.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "net/device_bound_sessions/session_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "services/network/public/mojom/device_bound_sessions.mojom.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_ANDROID)
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "base/android/apk_info.h"
#include "base/files/scoped_file.h"
#include "base/posix/eintr_wrapper.h"
#endif

namespace helium_sync {
namespace {

constexpr char kCookieKind[] = "cookies";
constexpr char kCookiePayloadFormat[] = "helium-cookie-v3";
constexpr char kRollbackPayloadFormat[] = "helium-cookie-rollback-v1";
constexpr int kStateSchema = 5;
constexpr int kRollbackSchema = 2;
constexpr int kReauthSchema = 3;
constexpr size_t kMaxCookieRecords = 50000;
constexpr size_t kMaxCookiePayloadBytes = 64 * 1024;
constexpr size_t kMaxRollbackPayloadBytes = 32 * 1024 * 1024;
constexpr size_t kMaxCookiePushRecords = 32;
constexpr base::TimeDelta kReconcileInterval = base::Minutes(1);

constexpr char kDeletedFingerprint[] = "deleted";
constexpr char kAcceptanceMarker[] = ".helium-cookie-disposable-profile-v1";
#if BUILDFLAG(IS_ANDROID)
constexpr char kAcceptanceMarkerContents[] =
    "helium-cookie-disposable-profile-v1\n";
#endif
constexpr char kAcceptanceReport[] =
    "helium-sync/cookie-native-acceptance.json";
constexpr char kAcceptanceRollback[] =
    "helium-sync/cookie-native-acceptance-rollback.json";

struct PendingPublish {
  int64_t expected_revision = 0;
  int64_t target_revision = 0;
  std::string payload_fingerprint;
  std::string cookie_fingerprint;
  bool deleted = false;
};

struct DestinationException {
  int64_t remote_revision = 0;
  std::string remote_payload_fingerprint;
  std::string reason;
  std::string schemeful_site;
  std::set<std::string> observed_session_ids;
  bool unverified_local_change = false;
};

struct RecordState {
  int64_t remote_revision = 0;
  std::string device_id;
  std::string remote_payload_fingerprint;
  std::string baseline_cookie_fingerprint;
  bool remote_deleted = false;
  std::optional<DestinationException> destination_exception;
  std::optional<PendingPublish> pending;
};

struct BridgeState {
  std::map<std::string, RecordState> records;
  std::string blocked_reason;
  int64_t verified_sequence = 0;
};

struct CookieSnapshot {
  std::map<std::string, net::CanonicalCookie> cookies;
  std::map<std::string, std::string> cookie_fingerprints;
  base::ListValue serialized;
  std::string fingerprint;
};

struct RemoteCookie {
  Record record;
  std::optional<net::CanonicalCookie> cookie;
  std::string payload_fingerprint;
  std::string cookie_fingerprint = kDeletedFingerprint;
  bool effective_deleted = false;
};

using DeviceBoundSessionInventory =
    std::map<std::string, std::set<std::string>>;

struct CookieOperation {
  bool set = false;
  std::string record_key;
  net::CanonicalCookie cookie;
  GURL source_url;
};

struct RollbackJournal {
  std::string status;
  std::string payload_json;
  std::string before_fingerprint;
  std::string target_fingerprint;
  size_t set_count = 0;
  size_t delete_count = 0;
};

std::string Sha256(std::string_view value) {
  return base::HexEncodeLower(crypto::SHA256HashString(value));
}

bool IsLowerHexDigest(std::string_view value) {
  return value.size() == 64 && std::ranges::all_of(value, [](char c) {
           return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
         });
}

std::string TimeToJSON(base::Time value) {
  return base::NumberToString(
      value.is_null() ? 0 : value.ToDeltaSinceWindowsEpoch().InMicroseconds());
}

std::optional<base::Time> TimeFromJSON(const base::DictValue &value,
                                       std::string_view key) {
  const std::string *encoded = value.FindString(key);
  int64_t micros = 0;
  if (!encoded || !base::StringToInt64(*encoded, &micros) || micros < 0) {
    return std::nullopt;
  }
  return micros == 0 ? base::Time()
                     : base::Time::FromDeltaSinceWindowsEpoch(
                           base::Microseconds(micros));
}

std::optional<int64_t> Int64FromJSON(const base::DictValue &value,
                                     std::string_view key) {
  const std::string *encoded = value.FindString(key);
  int64_t parsed = 0;
  if (!encoded || !base::StringToInt64(*encoded, &parsed) || parsed < 0) {
    return std::nullopt;
  }
  return parsed;
}

std::optional<base::DictValue>
CookieToValue(const net::CanonicalCookie &cookie) {
  base::DictValue value;
  value.Set("name", cookie.Name());
  value.Set("value", cookie.Value());
  value.Set("domain", cookie.Domain());
  value.Set("path", cookie.Path());
  value.Set("creation", TimeToJSON(cookie.CreationDate()));
  value.Set("expiry", TimeToJSON(cookie.ExpiryDate()));
  value.Set("last_access", TimeToJSON(cookie.LastAccessDate()));
  value.Set("last_update", TimeToJSON(cookie.LastUpdateDate()));
  value.Set("secure", cookie.SecureAttribute());
  value.Set("http_only", cookie.IsHttpOnly());
  value.Set("same_site", static_cast<int>(cookie.SameSite()));
  value.Set("priority", static_cast<int>(cookie.Priority()));
  value.Set("source_scheme", static_cast<int>(cookie.SourceScheme()));
  value.Set("source_port", cookie.SourcePort());
  value.Set("source_type", static_cast<int>(cookie.SourceType()));
  if (cookie.PartitionKey()) {
    auto serialized = net::CookiePartitionKey::Serialize(cookie.PartitionKey());
    if (!serialized.has_value()) {
      // Nonce partition keys cannot be reconstructed. Fail the whole snapshot
      // instead of silently dropping a live valid cookie.
      return std::nullopt;
    }
    base::DictValue partition;
    partition.Set("top_level_site", serialized->TopLevelSite());
    partition.Set("has_cross_site_ancestor",
                  serialized->has_cross_site_ancestor());
    value.Set("partition_key", std::move(partition));
  }
  return value;
}

std::optional<net::CanonicalCookie>
CookieFromValue(const base::DictValue &value) {
  const std::string *name = value.FindString("name");
  const std::string *cookie_value = value.FindString("value");
  const std::string *domain = value.FindString("domain");
  const std::string *path = value.FindString("path");
  std::optional<base::Time> creation = TimeFromJSON(value, "creation");
  std::optional<base::Time> expiry = TimeFromJSON(value, "expiry");
  std::optional<base::Time> last_access = TimeFromJSON(value, "last_access");
  std::optional<base::Time> last_update = TimeFromJSON(value, "last_update");
  std::optional<bool> secure = value.FindBool("secure");
  std::optional<bool> http_only = value.FindBool("http_only");
  std::optional<int> same_site = value.FindInt("same_site");
  std::optional<int> priority = value.FindInt("priority");
  std::optional<int> source_scheme = value.FindInt("source_scheme");
  std::optional<int> source_port = value.FindInt("source_port");
  std::optional<int> source_type = value.FindInt("source_type");
  if (!name || !cookie_value || !domain || domain->empty() || !path ||
      path->empty() || (*path)[0] != '/' || !creation || !expiry ||
      !last_access || !last_update || !secure || !http_only || !same_site ||
      !priority || !source_scheme || !source_port || !source_type ||
      *same_site < -1 || *same_site > 2 || *priority < 0 || *priority > 2 ||
      *source_scheme < 0 || *source_scheme > 2 || *source_port < -1 ||
      *source_port > 65535 || *source_type < 1 || *source_type > 3) {
    return std::nullopt;
  }

  std::optional<net::CookiePartitionKey> partition_key;
  if (const base::DictValue *partition = value.FindDict("partition_key")) {
    const std::string *top_level_site = partition->FindString("top_level_site");
    std::optional<bool> has_cross_site_ancestor =
        partition->FindBool("has_cross_site_ancestor");
    if (!top_level_site || !has_cross_site_ancestor) {
      return std::nullopt;
    }
    auto parsed = net::CookiePartitionKey::FromUntrustedInput(
        *top_level_site, *has_cross_site_ancestor);
    if (!parsed.has_value()) {
      return std::nullopt;
    }
    partition_key = std::move(*parsed);
  }

  std::unique_ptr<net::CanonicalCookie> cookie =
      net::CanonicalCookie::FromStorage(
          *name, *cookie_value, *domain, *path, *creation, *expiry,
          *last_access, *last_update, *secure, *http_only,
          static_cast<net::CookieSameSite>(*same_site),
          static_cast<net::CookiePriority>(*priority), std::move(partition_key),
          static_cast<net::CookieSourceScheme>(*source_scheme), *source_port,
          static_cast<net::CookieSourceType>(*source_type),
          net::CanonicalCookieFromStorageCallSite::kCookieManager);
  if (!cookie) {
    return std::nullopt;
  }
  return std::move(*cookie);
}

std::optional<std::string> CookieIdentity(const net::CanonicalCookie &cookie) {
  std::string identity;
  auto append = [&identity](std::string_view part) {
    identity += base::NumberToString(part.size());
    identity += ":";
    identity.append(part);
  };
  if (cookie.PartitionKey()) {
    auto serialized = net::CookiePartitionKey::Serialize(cookie.PartitionKey());
    if (!serialized.has_value()) {
      return std::nullopt;
    }
    append("partitioned");
    append(serialized->TopLevelSite());
    append(serialized->has_cross_site_ancestor() ? "1" : "0");
  } else {
    append("unpartitioned");
  }
  append(cookie.Domain());
  append(cookie.Path());
  append(cookie.Name());
  append(base::NumberToString(static_cast<int>(cookie.SourceScheme())));
  append(base::NumberToString(cookie.SourcePort()));
  return identity;
}

std::optional<std::string> CookieRecordKey(const net::CanonicalCookie &cookie) {
  std::optional<std::string> identity = CookieIdentity(cookie);
  return identity ? std::optional<std::string>(Sha256(*identity))
                  : std::nullopt;
}

std::optional<std::string>
CookieFingerprint(const net::CanonicalCookie &cookie) {
  std::optional<base::DictValue> value = CookieToValue(cookie);
  if (!value) {
    return std::nullopt;
  }
  // Chromium reads update these fields and a destination may not recreate
  // them byte-for-byte. They are retained for rollback but never count as a
  // user/session mutation.
  value->Remove("creation");
  value->Remove("last_access");
  value->Remove("last_update");
  std::string raw;
  if (!base::JSONWriter::Write(*value, &raw)) {
    return std::nullopt;
  }
  return Sha256(raw);
}

std::optional<CookieSnapshot>
BuildSnapshot(std::vector<net::CanonicalCookie> cookies,
              base::Time now = base::Time::Now()) {
  CookieSnapshot out;
  for (net::CanonicalCookie &cookie : cookies) {
    if (cookie.IsExpired(now)) {
      continue;
    }
    std::optional<std::string> key = CookieRecordKey(cookie);
    std::optional<std::string> fingerprint = CookieFingerprint(cookie);
    if (!key || !fingerprint || out.cookies.contains(*key)) {
      return std::nullopt;
    }
    out.cookie_fingerprints[*key] = std::move(*fingerprint);
    out.cookies.emplace(*key, std::move(cookie));
  }
  if (out.cookies.size() > kMaxCookieRecords) {
    return std::nullopt;
  }
  std::string fingerprint_input;
  for (const auto &[key, cookie] : out.cookies) {
    std::optional<base::DictValue> value = CookieToValue(cookie);
    if (!value) {
      return std::nullopt;
    }
    out.serialized.Append(std::move(*value));
    fingerprint_input += key + "\0" + out.cookie_fingerprints.at(key) + "\n";
  }
  out.fingerprint = Sha256(fingerprint_input);
  return out;
}

CookieSnapshot CloneSnapshot(const CookieSnapshot &snapshot) {
  return CookieSnapshot{snapshot.cookies, snapshot.cookie_fingerprints,
                        snapshot.serialized.Clone(), snapshot.fingerprint};
}

GURL SourceUrlForCookie(const net::CanonicalCookie &cookie) {
  std::string source =
      cookie.SourceScheme() == net::CookieSourceScheme::kSecure ||
              cookie.SecureAttribute()
          ? "https://"
          : "http://";
  source += cookie.DomainWithoutDot();
  if (cookie.SourcePort() >= 0 && cookie.SourcePort() <= 65535 &&
      !((source.starts_with("https://") && cookie.SourcePort() == 443) ||
        (source.starts_with("http://") && cookie.SourcePort() == 80))) {
    source += ":" + base::NumberToString(cookie.SourcePort());
  }
  source += cookie.Path();
  return GURL(source);
}

std::string SchemefulSiteForCookie(const net::CanonicalCookie &cookie) {
  GURL source = SourceUrlForCookie(cookie);
  return source.is_valid() ? net::SchemefulSite(source).Serialize() : "";
}

std::optional<std::string>
MakeCookiePayload(const net::CanonicalCookie &cookie) {
  std::optional<base::DictValue> serialized = CookieToValue(cookie);
  if (!serialized) {
    return std::nullopt;
  }
  base::DictValue root;
  root.Set("format", kCookiePayloadFormat);
  root.Set("cookie", std::move(*serialized));
  std::string raw;
  if (!base::JSONWriter::Write(root, &raw) ||
      raw.size() > kMaxCookiePayloadBytes) {
    return std::nullopt;
  }
  return raw;
}

std::optional<RemoteCookie> ParseRemoteCookie(Record record) {
  RemoteCookie out;
  out.record = std::move(record);
  if (out.record.deleted) {
    std::optional<base::Value> tombstone_payload =
        base::JSONReader::Read(out.record.payload_json, base::JSON_PARSE_RFC);
    if (!tombstone_payload || !tombstone_payload->is_dict() ||
        !tombstone_payload->GetDict().empty()) {
      return std::nullopt;
    }
    out.payload_fingerprint = kDeletedFingerprint;
    out.effective_deleted = true;
    return out;
  }
  if (out.record.payload_json.empty() ||
      out.record.payload_json.size() > kMaxCookiePayloadBytes) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(out.record.payload_json, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return std::nullopt;
  }
  const std::string *format = parsed->GetDict().FindString("format");
  if (!format || *format != kCookiePayloadFormat) {
    return std::nullopt;
  }
  const base::DictValue *cookie_value = parsed->GetDict().FindDict("cookie");
  if (!cookie_value) {
    return std::nullopt;
  }
  std::optional<net::CanonicalCookie> cookie = CookieFromValue(*cookie_value);
  if (!cookie) {
    return std::nullopt;
  }
  std::optional<std::string> key = CookieRecordKey(*cookie);
  std::optional<std::string> fingerprint = CookieFingerprint(*cookie);
  if (!key || *key != out.record.key || !fingerprint) {
    return std::nullopt;
  }
  out.payload_fingerprint = Sha256(out.record.payload_json);
  out.cookie_fingerprint = std::move(*fingerprint);
  out.effective_deleted = cookie->IsExpired(base::Time::Now());
  if (!out.effective_deleted) {
    out.cookie = std::move(*cookie);
  }
  return out;
}

bool WriteSecretFile(const base::FilePath &path, std::string_view contents) {
  if (!base::CreateDirectory(path.DirName()) ||
      !base::ImportantFileWriter::WriteFileAtomically(path, contents,
                                                      "HeliumSync")) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  return base::SetPosixFilePermissions(path, 0600);
#else
  return true;
#endif
}

base::DictValue RecordStateToValue(const RecordState &state) {
  base::DictValue value;
  value.Set("remote_revision", base::NumberToString(state.remote_revision));
  value.Set("device_id", state.device_id);
  value.Set("remote_payload_fingerprint", state.remote_payload_fingerprint);
  value.Set("baseline_cookie_fingerprint", state.baseline_cookie_fingerprint);
  value.Set("remote_deleted", state.remote_deleted);
  if (state.destination_exception) {
    base::DictValue exception;
    exception.Set(
        "remote_revision",
        base::NumberToString(state.destination_exception->remote_revision));
    exception.Set("remote_payload_fingerprint",
                  state.destination_exception->remote_payload_fingerprint);
    exception.Set("reason", state.destination_exception->reason);
    exception.Set("schemeful_site",
                  state.destination_exception->schemeful_site);
    exception.Set("unverified_local_change",
                  state.destination_exception->unverified_local_change);
    base::ListValue sessions;
    for (const std::string &session_id :
         state.destination_exception->observed_session_ids) {
      sessions.Append(session_id);
    }
    exception.Set("observed_session_ids", std::move(sessions));
    value.Set("destination_exception", std::move(exception));
  }
  if (state.pending) {
    base::DictValue pending;
    pending.Set("expected_revision",
                base::NumberToString(state.pending->expected_revision));
    pending.Set("target_revision",
                base::NumberToString(state.pending->target_revision));
    pending.Set("payload_fingerprint", state.pending->payload_fingerprint);
    pending.Set("cookie_fingerprint", state.pending->cookie_fingerprint);
    pending.Set("deleted", state.pending->deleted);
    value.Set("pending_publish", std::move(pending));
  }
  return value;
}

std::optional<RecordState> RecordStateFromValue(const base::DictValue &value) {
  RecordState state;
  std::optional<int64_t> revision = Int64FromJSON(value, "remote_revision");
  const std::string *device_id = value.FindString("device_id");
  const std::string *remote_payload =
      value.FindString("remote_payload_fingerprint");
  const std::string *baseline = value.FindString("baseline_cookie_fingerprint");
  std::optional<bool> deleted = value.FindBool("remote_deleted");
  if (!revision || !device_id || !remote_payload || !baseline || !deleted) {
    return std::nullopt;
  }
  state.remote_revision = *revision;
  state.device_id = *device_id;
  state.remote_payload_fingerprint = *remote_payload;
  state.baseline_cookie_fingerprint = *baseline;
  state.remote_deleted = *deleted;
  if (const base::DictValue *exception =
          value.FindDict("destination_exception")) {
    DestinationException parsed;
    std::optional<int64_t> exception_revision =
        Int64FromJSON(*exception, "remote_revision");
    const std::string *exception_payload =
        exception->FindString("remote_payload_fingerprint");
    const std::string *reason = exception->FindString("reason");
    const std::string *schemeful_site = exception->FindString("schemeful_site");
    std::optional<bool> unverified_local_change =
        exception->FindBool("unverified_local_change");
    const base::ListValue *sessions =
        exception->FindList("observed_session_ids");
    if (!exception_revision || *exception_revision <= 0 || !exception_payload ||
        !IsLowerHexDigest(*exception_payload) || !reason || reason->empty() ||
        !schemeful_site || schemeful_site->empty() ||
        !unverified_local_change || !sessions) {
      return std::nullopt;
    }
    GURL schemeful_site_url(*schemeful_site);
    if (!schemeful_site_url.is_valid() ||
        net::SchemefulSite(schemeful_site_url).opaque() ||
        net::SchemefulSite(schemeful_site_url).Serialize() != *schemeful_site) {
      return std::nullopt;
    }
    parsed.remote_revision = *exception_revision;
    parsed.remote_payload_fingerprint = *exception_payload;
    parsed.reason = *reason;
    parsed.schemeful_site = *schemeful_site;
    parsed.unverified_local_change = *unverified_local_change;
    for (const base::Value &session : *sessions) {
      if (!session.is_string() || session.GetString().empty() ||
          !parsed.observed_session_ids.insert(session.GetString()).second) {
        return std::nullopt;
      }
    }
    if (parsed.remote_revision != state.remote_revision ||
        parsed.remote_payload_fingerprint != state.remote_payload_fingerprint) {
      return std::nullopt;
    }
    state.destination_exception = std::move(parsed);
  }
  if (const base::DictValue *pending = value.FindDict("pending_publish")) {
    PendingPublish parsed;
    std::optional<int64_t> expected =
        Int64FromJSON(*pending, "expected_revision");
    std::optional<int64_t> target = Int64FromJSON(*pending, "target_revision");
    const std::string *payload = pending->FindString("payload_fingerprint");
    const std::string *cookie = pending->FindString("cookie_fingerprint");
    std::optional<bool> pending_deleted = pending->FindBool("deleted");
    if (!expected || !target || *target != *expected + 1 || !payload ||
        !cookie || !pending_deleted) {
      return std::nullopt;
    }
    parsed.expected_revision = *expected;
    parsed.target_revision = *target;
    parsed.payload_fingerprint = *payload;
    parsed.cookie_fingerprint = *cookie;
    parsed.deleted = *pending_deleted;
    state.pending = std::move(parsed);
  }
  return state;
}

std::vector<CookieOperation> DiffSnapshots(const CookieSnapshot &before,
                                           const CookieSnapshot &after,
                                           const std::set<std::string> &keys) {
  std::vector<CookieOperation> operations;
  for (const std::string &key : keys) {
    auto old_cookie = before.cookies.find(key);
    auto new_cookie = after.cookies.find(key);
    if (old_cookie != before.cookies.end() &&
        new_cookie == after.cookies.end()) {
      operations.push_back({false, key, old_cookie->second, GURL()});
      continue;
    }
    if (new_cookie != after.cookies.end() &&
        (old_cookie == before.cookies.end() ||
         before.cookie_fingerprints.at(key) !=
             after.cookie_fingerprints.at(key))) {
      operations.push_back({true, key, new_cookie->second,
                            SourceUrlForCookie(new_cookie->second)});
    }
  }
  return operations;
}

std::set<std::string> AllSnapshotKeys(const CookieSnapshot &left,
                                      const CookieSnapshot &right) {
  std::set<std::string> keys;
  for (const auto &[key, cookie] : left.cookies) {
    keys.insert(key);
  }
  for (const auto &[key, cookie] : right.cookies) {
    keys.insert(key);
  }
  return keys;
}

std::optional<CookieSnapshot>
RefreshLiveSnapshot(const CookieSnapshot &snapshot) {
  std::vector<net::CanonicalCookie> cookies;
  cookies.reserve(snapshot.cookies.size());
  for (const auto &[key, cookie] : snapshot.cookies) {
    cookies.push_back(cookie);
  }
  return BuildSnapshot(std::move(cookies));
}

} // namespace

class HeliumCookieAcceptanceFixture::Impl {
public:
  explicit Impl(Profile *profile)
      : profile_(profile),
        marker_path_(profile->GetPath().AppendASCII(kAcceptanceMarker)),
        output_dir_(profile->GetPath().AppendASCII("helium-sync")),
        report_path_(profile->GetPath().AppendASCII(kAcceptanceReport)),
        rollback_path_(profile->GetPath().AppendASCII(kAcceptanceRollback)) {}

  void Start() {
    if (started_) {
      return;
    }
    started_ = true;

#if BUILDFLAG(IS_ANDROID)
    std::string marker;
    if (profile_->GetPath().BaseName().AsUTF8Unsafe() != "Default" ||
        base::IsLink(profile_->GetPath()) || !ReadAcceptanceMarker(&marker) ||
        marker != kAcceptanceMarkerContents || base::PathExists(output_dir_) ||
        base::IsLink(output_dir_) || base::PathExists(report_path_) ||
        base::IsLink(report_path_) || base::PathExists(rollback_path_) ||
        base::IsLink(rollback_path_)) {
      Fail("disposable-profile-marker-or-output-invalid");
      return;
    }
    output_paths_admitted_ = true;
    if (base::android::apk_info::package_name() !=
            "computer.helium.sync.test" ||
        !base::android::apk_info::is_debug_app()) {
      Fail("fixture-requires-debuggable-sync-test-package");
      return;
    }

    manager()->GetAllCookies(
        base::BindOnce(&Impl::OnInitialCookies, weak_factory_.GetWeakPtr()));
#else
    Fail("fixture-requires-android");
#endif
  }

  void Stop() {
    stopped_ = true;
    operation_queue_.clear();
    weak_factory_.InvalidateWeakPtrs();
  }

private:
  enum class Phase {
    kIdle,
    kSeedingDestination,
    kApplyingImport,
    kExpectingRejection,
    kRestoringDestination,
    kCleaning,
  };

  network::mojom::CookieManager *manager() {
    return profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess();
  }

#if BUILDFLAG(IS_ANDROID)
  bool ReadAcceptanceMarker(std::string *contents) {
    constexpr size_t kExpectedSize = sizeof(kAcceptanceMarkerContents) - 1;
    base::ScopedFD marker_fd(
        HANDLE_EINTR(open(marker_path_.value().c_str(),
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)));
    struct stat marker_stat;
    if (!marker_fd.is_valid() ||
        HANDLE_EINTR(fstat(marker_fd.get(), &marker_stat)) != 0 ||
        !S_ISREG(marker_stat.st_mode) || (marker_stat.st_mode & 0777) != 0600 ||
        marker_stat.st_size != static_cast<off_t>(kExpectedSize)) {
      return false;
    }

    contents->assign(kExpectedSize, '\0');
    size_t offset = 0;
    while (offset < contents->size()) {
      const ssize_t read_size =
          HANDLE_EINTR(read(marker_fd.get(), contents->data() + offset,
                            contents->size() - offset));
      if (read_size <= 0) {
        contents->clear();
        return false;
      }
      offset += static_cast<size_t>(read_size);
    }
    char trailing;
    if (HANDLE_EINTR(read(marker_fd.get(), &trailing, 1)) != 0) {
      contents->clear();
      return false;
    }
    return true;
  }
#endif

  bool CanWriteAcceptanceFile(const base::FilePath &path) const {
    if (!output_paths_admitted_ || path.DirName() != output_dir_ ||
        base::IsLink(output_dir_) ||
        (base::PathExists(output_dir_) &&
         !base::DirectoryExists(output_dir_)) ||
        base::PathExists(path) || base::IsLink(path)) {
      return false;
    }
#if BUILDFLAG(IS_POSIX)
    int directory_permissions = 0;
    if (base::DirectoryExists(output_dir_) &&
        (!base::GetPosixFilePermissions(output_dir_, &directory_permissions) ||
         directory_permissions != 0700)) {
      return false;
    }
#endif
    return true;
  }

  bool WriteAcceptanceFile(const base::FilePath &path,
                           std::string_view contents) {
    if (!CanWriteAcceptanceFile(path) || !WriteSecretFile(path, contents) ||
        base::IsLink(output_dir_) || base::IsLink(path) ||
        !base::DirectoryExists(output_dir_)) {
      return false;
    }
#if BUILDFLAG(IS_POSIX)
    int directory_permissions = 0;
    int file_permissions = 0;
    if (!base::GetPosixFilePermissions(output_dir_, &directory_permissions) ||
        directory_permissions != 0700 ||
        !base::GetPosixFilePermissions(path, &file_permissions) ||
        file_permissions != 0600) {
      return false;
    }
#endif
    return true;
  }

  std::optional<net::CanonicalCookie>
  MakeCookie(std::string value, std::string domain, bool persistent,
             std::optional<net::CookiePartitionKey> partition_key,
             net::CookieSameSite same_site) {
    const base::Time now = base::Time::Now();
    std::unique_ptr<net::CanonicalCookie> cookie =
        net::CanonicalCookie::FromStorage(
            "helium_native_session", std::move(value), std::move(domain), "/",
            now, persistent ? now + base::Days(7) : base::Time(), now, now,
            true, true, same_site, net::COOKIE_PRIORITY_MEDIUM,
            std::move(partition_key), net::CookieSourceScheme::kSecure, 443,
            net::CookieSourceType::kHTTP,
            net::CanonicalCookieFromStorageCallSite::kCookieManager);
    if (!cookie) {
      return std::nullopt;
    }
    return std::move(*cookie);
  }

  std::optional<CookieSnapshot> MakeDestinationSnapshot() {
    std::optional<net::CanonicalCookie> cookie =
        MakeCookie("destination-baseline", "login.helium.invalid", false,
                   std::nullopt, static_cast<net::CookieSameSite>(1));
    if (!cookie) {
      return std::nullopt;
    }
    std::vector<net::CanonicalCookie> cookies;
    cookies.push_back(std::move(*cookie));
    return BuildSnapshot(std::move(cookies));
  }

  std::optional<CookieSnapshot> MakeImportSnapshot() {
    auto partition_key = net::CookiePartitionKey::FromUntrustedInput(
        "https://top.helium.invalid", true);
    if (!partition_key.has_value()) {
      return std::nullopt;
    }
    std::optional<net::CanonicalCookie> rotated =
        MakeCookie("imported-rotation", "login.helium.invalid", false,
                   std::nullopt, static_cast<net::CookieSameSite>(1));
    std::optional<net::CanonicalCookie> partitioned = MakeCookie(
        "partitioned-session", "login.helium.invalid", false,
        std::move(*partition_key), static_cast<net::CookieSameSite>(0));
    std::optional<net::CanonicalCookie> domain =
        MakeCookie("persistent-domain", ".helium.invalid", true, std::nullopt,
                   static_cast<net::CookieSameSite>(2));
    if (!rotated || !partitioned || !domain) {
      return std::nullopt;
    }
    std::vector<net::CanonicalCookie> cookies;
    cookies.push_back(std::move(*rotated));
    cookies.push_back(std::move(*partitioned));
    cookies.push_back(std::move(*domain));
    return BuildSnapshot(std::move(cookies));
  }

  void OnInitialCookies(const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> initial = BuildSnapshot(cookies);
    if (!initial || !initial->cookies.empty()) {
      Fail("fixture-profile-must-start-with-empty-cookie-store");
      return;
    }
    std::optional<CookieSnapshot> destination = MakeDestinationSnapshot();
    if (!destination || destination->cookies.size() != 1) {
      Fail("destination-snapshot-construction-failed");
      return;
    }
    destination_ = std::move(*destination);
    BeginOperations(*initial, destination_, Phase::kSeedingDestination);
  }

  void BeginOperations(const CookieSnapshot &before,
                       const CookieSnapshot &after, Phase phase) {
    std::set<std::string> keys = AllSnapshotKeys(before, after);
    std::vector<CookieOperation> operations =
        DiffSnapshots(before, after, keys);
    operation_queue_ =
        std::deque<CookieOperation>(std::make_move_iterator(operations.begin()),
                                    std::make_move_iterator(operations.end()));
    phase_ = phase;
    StartNextOperation();
  }

  void StartNextOperation() {
    if (stopped_ || terminal_) {
      return;
    }
    if (operation_queue_.empty()) {
      manager()->GetAllCookies(
          base::BindOnce(&Impl::OnPhaseCookies, weak_factory_.GetWeakPtr()));
      return;
    }
    current_operation_ = std::move(operation_queue_.front());
    operation_queue_.pop_front();
    if (current_operation_->set) {
      if (!current_operation_->source_url.is_valid()) {
        Fail("fixture-cookie-source-url-invalid");
        return;
      }
      manager()->SetCanonicalCookie(
          current_operation_->cookie, current_operation_->source_url,
          net::CookieOptions::MakeAllInclusive(),
          base::BindOnce(&Impl::OnCookieSet, weak_factory_.GetWeakPtr()));
      return;
    }
    manager()->DeleteCanonicalCookie(
        current_operation_->cookie,
        base::BindOnce(&Impl::OnCookieDeleted, weak_factory_.GetWeakPtr()));
  }

  void OnCookieSet(net::CookieAccessResult result) {
    if (phase_ == Phase::kExpectingRejection) {
      current_operation_.reset();
      if (result.status.IsInclude()) {
        Fail("negative-cookie-operation-was-accepted");
        return;
      }
      rejection_observed_ = true;
      manager()->GetAllCookies(base::BindOnce(&Impl::OnPreRollbackCookies,
                                              weak_factory_.GetWeakPtr()));
      return;
    }
    if (!result.status.IsInclude()) {
      Fail("native-cookie-operation-was-rejected");
      return;
    }
    current_operation_.reset();
    StartNextOperation();
  }

  void OnCookieDeleted(bool) {
    current_operation_.reset();
    StartNextOperation();
  }

  void OnPhaseCookies(const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> current = BuildSnapshot(cookies);
    if (!current) {
      Fail("native-cookie-readback-invalid");
      return;
    }
    if (phase_ == Phase::kSeedingDestination) {
      if (current->fingerprint != destination_.fingerprint ||
          !SaveDestinationSnapshot()) {
        Fail("destination-snapshot-persist-or-readback-failed");
        return;
      }
      std::optional<CookieSnapshot> imported = MakeImportSnapshot();
      if (!imported || imported->cookies.size() != 3) {
        Fail("import-preview-construction-failed");
        return;
      }
      import_ = std::move(*imported);
      if (!HasDistinctPartitionIdentities(import_)) {
        Fail("canonical-partition-identity-collapsed");
        return;
      }
      BeginOperations(destination_, import_, Phase::kApplyingImport);
      return;
    }
    if (phase_ == Phase::kApplyingImport) {
      if (current->fingerprint != import_.fingerprint) {
        Fail("import-apply-readback-mismatch");
        return;
      }
      import_readback_verified_ = true;
      BeginRejectedOperation();
      return;
    }
    if (phase_ == Phase::kRestoringDestination) {
      if (current->fingerprint != destination_.fingerprint) {
        Fail("destination-rollback-readback-mismatch");
        return;
      }
      rollback_verified_ = true;
      CookieSnapshot empty;
      BeginOperations(destination_, empty, Phase::kCleaning);
      return;
    }
    if (phase_ == Phase::kCleaning) {
      if (!current->cookies.empty() || !base::DeleteFile(rollback_path_)) {
        Fail("fixture-cleanup-failed");
        return;
      }
      cleanup_verified_ = true;
      Pass();
      return;
    }
    Fail("fixture-phase-invalid");
  }

  bool SaveDestinationSnapshot() {
    base::DictValue root;
    root.Set("format", "helium-cookie-native-acceptance-rollback-v1");
    root.Set("cookies", destination_.serialized.Clone());
    root.Set("fingerprint", destination_.fingerprint);
    std::string raw;
    return base::JSONWriter::Write(root, &raw) &&
           WriteAcceptanceFile(rollback_path_, raw);
  }

  bool HasDistinctPartitionIdentities(const CookieSnapshot &snapshot) {
    size_t unpartitioned = 0;
    size_t partitioned = 0;
    std::set<std::string> keys;
    for (const auto &[key, cookie] : snapshot.cookies) {
      keys.insert(key);
      if (cookie.PartitionKey()) {
        ++partitioned;
      } else if (cookie.Domain() == "login.helium.invalid") {
        ++unpartitioned;
      }
    }
    return keys.size() == snapshot.cookies.size() && partitioned == 1 &&
           unpartitioned == 1;
  }

  void BeginRejectedOperation() {
    std::optional<net::CanonicalCookie> rejected =
        MakeCookie("must-be-rejected", "rejected.helium.invalid", false,
                   std::nullopt, static_cast<net::CookieSameSite>(1));
    if (!rejected) {
      Fail("negative-cookie-construction-failed");
      return;
    }
    current_operation_ =
        CookieOperation{true, "", std::move(*rejected),
                        GURL("http://rejected.helium.invalid/")};
    phase_ = Phase::kExpectingRejection;
    manager()->SetCanonicalCookie(
        current_operation_->cookie, current_operation_->source_url,
        net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(&Impl::OnCookieSet, weak_factory_.GetWeakPtr()));
  }

  void OnPreRollbackCookies(
      const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> current = BuildSnapshot(cookies);
    if (!current || current->fingerprint != import_.fingerprint) {
      Fail("rejected-operation-mutated-cookie-store");
      return;
    }
    BeginOperations(*current, destination_, Phase::kRestoringDestination);
  }

  base::DictValue Report(std::string status, std::string reason) {
    base::DictValue report;
    report.Set("schema_version", 1);
    report.Set("fixture", "helium-cookie-manager-disposable-v1");
    report.Set("synthetic_only", true);
    report.Set("status", std::move(status));
    report.Set("reason", std::move(reason));
    report.Set("cookie_api", "network::mojom::CookieManager");

    base::DictValue destination;
    destination.Set("complete_profile_cookie_count", 1);
    destination.Set("snapshot_persisted_before_apply",
                    base::PathExists(rollback_path_) || rollback_verified_);
    destination.Set("fingerprint", destination_.fingerprint);
    report.Set("destination_snapshot", std::move(destination));

    base::DictValue imported;
    imported.Set("record_count", 3);
    imported.Set("apply_result",
                 import_readback_verified_ ? "accepted" : "not-complete");
    imported.Set("readback_result",
                 import_readback_verified_ ? "exact" : "not-complete");
    imported.Set("fingerprint", import_.fingerprint);
    imported.Set("canonical_record_keys_unique", import_.cookies.size() == 3);
    imported.Set("partitioned_and_unpartitioned_identity_distinct",
                 HasDistinctPartitionIdentities(import_));
    base::DictValue attributes;
    attributes.Set("session", true);
    attributes.Set("persistent", true);
    attributes.Set("http_only", true);
    attributes.Set("secure", true);
    attributes.Set("same_site", true);
    attributes.Set("host_only", true);
    attributes.Set("domain", true);
    attributes.Set("partitioned", true);
    imported.Set("attribute_coverage", std::move(attributes));
    report.Set("import", std::move(imported));

    base::DictValue rejection;
    rejection.Set("set_result",
                  rejection_observed_ ? "rejected" : "not-complete");
    rejection.Set("rollback_result",
                  rollback_verified_ ? "exact" : "not-complete");
    rejection.Set("destination_fingerprint", destination_.fingerprint);
    report.Set("destination_rejection", std::move(rejection));

    base::DictValue origin_state;
    origin_state.Set("cookie_names_guessed", false);
    origin_state.Set("cookie_manager_supported", true);
    origin_state.Set("registered_adapter_count", 0);
    origin_state.Set("non_cookie_transfer_result", "not-tested");
    report.Set("origin_state", std::move(origin_state));

    base::DictValue cleanup;
    cleanup.Set("complete_profile_cookie_store",
                cleanup_verified_ ? "empty" : "not-complete");
    report.Set("cleanup", std::move(cleanup));
    return report;
  }

  void Pass() {
    if (terminal_) {
      return;
    }
    terminal_ = true;
    std::string raw;
    base::DictValue report = Report("passed", "");
    if (!base::JSONWriter::Write(report, &raw) ||
        !WriteAcceptanceFile(report_path_, raw)) {
      LOG(ERROR) << "Helium cookie acceptance could not write its result";
      return;
    }
    LOG(WARNING) << "Helium cookie acceptance passed";
  }

  void Fail(std::string reason) {
    if (terminal_) {
      return;
    }
    terminal_ = true;
    operation_queue_.clear();
    current_operation_.reset();
    std::string raw;
    base::DictValue report = Report("failed", reason);
    if (output_paths_admitted_ && !base::PathExists(report_path_) &&
        !base::IsLink(report_path_) && base::JSONWriter::Write(report, &raw)) {
      WriteAcceptanceFile(report_path_, raw);
    }
    LOG(ERROR) << "Helium cookie acceptance failed: " << reason;
  }

  raw_ptr<Profile> profile_;
  const base::FilePath marker_path_;
  const base::FilePath output_dir_;
  const base::FilePath report_path_;
  const base::FilePath rollback_path_;
  CookieSnapshot destination_;
  CookieSnapshot import_;
  std::deque<CookieOperation> operation_queue_;
  std::optional<CookieOperation> current_operation_;
  Phase phase_ = Phase::kIdle;
  bool started_ = false;
  bool stopped_ = false;
  bool terminal_ = false;
  bool import_readback_verified_ = false;
  bool rejection_observed_ = false;
  bool rollback_verified_ = false;
  bool cleanup_verified_ = false;
  bool output_paths_admitted_ = false;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

HeliumCookieAcceptanceFixture::HeliumCookieAcceptanceFixture(Profile *profile)
    : impl_(std::make_unique<Impl>(profile)) {}

HeliumCookieAcceptanceFixture::~HeliumCookieAcceptanceFixture() = default;

bool HeliumCookieAcceptanceFixture::IsRequested(Profile *profile) {
  const base::FilePath marker =
      profile->GetPath().AppendASCII(kAcceptanceMarker);
  return base::PathExists(marker) || base::IsLink(marker);
}

void HeliumCookieAcceptanceFixture::Start() { impl_->Start(); }

void HeliumCookieAcceptanceFixture::Stop() { impl_->Stop(); }

class HeliumCookieSyncBridge::Impl {
public:
  Impl(Profile *profile, std::unique_ptr<HeliumSyncClient> client,
       base::FilePath state_path, base::FilePath rollback_path,
       base::FilePath reauth_signal_path,
       base::RepeatingCallback<void(int64_t)> verified_baseline_callback)
      : profile_(profile), client_(std::move(client)),
        state_path_(std::move(state_path)),
        rollback_path_(std::move(rollback_path)),
        reauth_signal_path_(std::move(reauth_signal_path)),
        verified_baseline_callback_(std::move(verified_baseline_callback)) {}

  ~Impl() { Stop(); }

  void Start() {
    if (!profile_ || !client_ || !LoadState() || !WriteReauthSignal()) {
      LOG(WARNING) << "Helium cookie sync inactive: state is invalid";
      return;
    }
    reconcile_timer_.Start(
        FROM_HERE, kReconcileInterval,
        base::BindRepeating(&Impl::Reconcile, weak_factory_.GetWeakPtr()));
    std::optional<RollbackJournal> journal = LoadRollback();
    if (base::PathExists(rollback_path_) && !journal) {
      Block("cookie-rollback-journal-invalid");
      return;
    }
    if (journal && journal->status == "pending") {
      RecoverRollback(std::move(*journal));
      return;
    }
    Reconcile();
  }

  void Stop() {
    reconcile_timer_.Stop();
    weak_factory_.InvalidateWeakPtrs();
    reconcile_in_flight_ = false;
    operation_queue_.clear();
  }

  void PullAndApply() { Reconcile(); }

  bool EnrollmentActivated(std::string *error) {
    if (!client_ || !client_->ReloadEnrollmentState(error)) {
      return false;
    }
    if (client_->enrollment_phase() != "active") {
      if (error) {
        *error = "cookie client enrollment is not active";
      }
      return false;
    }
    verified_baseline_callback_.Reset();
    return true;
  }

private:
  bool LoadState() {
    state_ = BridgeState();
    if (!base::PathExists(state_path_)) {
      return true;
    }
    std::string raw;
    std::optional<base::Value> parsed;
    if (!base::ReadFileToString(state_path_, &raw) ||
        !(parsed = base::JSONReader::Read(raw, base::JSON_PARSE_RFC)) ||
        !parsed->is_dict()) {
      return false;
    }
    int schema = parsed->GetDict().FindInt("schema_version").value_or(0);
    if (schema != kStateSchema) {
      return false;
    }
    if (const std::string *blocked =
            parsed->GetDict().FindString("blocked_reason")) {
      state_.blocked_reason = *blocked;
    }
    std::optional<int64_t> verified_sequence =
        Int64FromJSON(parsed->GetDict(), "verified_sequence");
    if (!verified_sequence) {
      return false;
    }
    state_.verified_sequence = *verified_sequence;
    const base::DictValue *records = parsed->GetDict().FindDict("records");
    if (!records) {
      return false;
    }
    for (const auto [key, value] : *records) {
      if (!IsLowerHexDigest(key) || !value.is_dict()) {
        return false;
      }
      std::optional<RecordState> record = RecordStateFromValue(value.GetDict());
      if (!record) {
        return false;
      }
      state_.records.emplace(key, std::move(*record));
    }
    return true;
  }

  bool SaveState() const {
    base::DictValue records;
    for (const auto &[key, record] : state_.records) {
      records.Set(key, RecordStateToValue(record));
    }
    base::DictValue root;
    root.Set("schema_version", kStateSchema);
    root.Set("verified_sequence",
             base::NumberToString(state_.verified_sequence));
    root.Set("blocked_reason", state_.blocked_reason);
    root.Set("records", std::move(records));
    std::string raw;
    return base::JSONWriter::Write(root, &raw) &&
           WriteSecretFile(state_path_, raw) && WriteReauthSignal();
  }

  void Block(std::string reason) {
    LOG(WARNING) << "Helium cookie sync stopped: " << reason;
    state_.blocked_reason = std::move(reason);
    SaveState();
    reconcile_in_flight_ = false;
  }

  void Reconcile() {
    if (reconcile_in_flight_ || !state_.blocked_reason.empty()) {
      return;
    }
    reconcile_in_flight_ = true;
    client_->Latest({kCookieKind}, base::BindOnce(&Impl::OnLatest,
                                                  weak_factory_.GetWeakPtr()));
  }

  void OnLatest(bool ok, RecordsResult result, std::string error) {
    if (!ok) {
      LOG(WARNING) << "Helium cookie pull failed: " << error;
      reconcile_in_flight_ = false;
      return;
    }
    if (result.records.size() > kMaxCookieRecords) {
      Block("remote-cookie-record-limit-exceeded");
      return;
    }
    pending_next_seq_ = result.next_seq;
    std::map<std::string, RemoteCookie> remote;
    for (Record &record : result.records) {
      if (record.kind != kCookieKind || !IsLowerHexDigest(record.key)) {
        Block("legacy-or-malformed-cookie-record");
        return;
      }
      if (record.revision <= 0 || record.device_id.empty() ||
          remote.contains(record.key)) {
        Block("malformed-cookie-authority-metadata");
        return;
      }
      std::optional<RemoteCookie> parsed = ParseRemoteCookie(std::move(record));
      if (!parsed) {
        Block("malformed-cookie-record-payload");
        return;
      }
      remote.emplace(parsed->record.key, std::move(*parsed));
    }
    profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->GetAllCookies(base::BindOnce(
            &Impl::OnCookies, weak_factory_.GetWeakPtr(), std::move(remote)));
  }

  void OnCookies(std::map<std::string, RemoteCookie> remote,
                 const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> local = BuildSnapshot(cookies);
    if (!local) {
      Block("local-cookie-snapshot-not-fully-serializable");
      return;
    }
    auto *manager =
        profile_->GetDefaultStoragePartition()->GetDeviceBoundSessionManager();
    if (!manager) {
      ReconcileSnapshots(std::move(remote), std::move(*local),
                         DeviceBoundSessionInventory());
      return;
    }
    manager->GetAllSessions(
        base::BindOnce(&Impl::OnDeviceBoundSessions, weak_factory_.GetWeakPtr(),
                       std::move(remote), std::move(*local)));
  }

  void OnDeviceBoundSessions(
      std::map<std::string, RemoteCookie> remote, CookieSnapshot local,
      const std::vector<net::device_bound_sessions::SessionKey> &sessions) {
    DeviceBoundSessionInventory inventory;
    for (const auto &session : sessions) {
      if (session.site.opaque() || session.id.value().empty()) {
        continue;
      }
      inventory[session.site.Serialize()].insert(session.id.value());
    }
    ReconcileSnapshots(std::move(remote), std::move(local),
                       std::move(inventory));
  }

  void ReconcileSnapshots(std::map<std::string, RemoteCookie> remote,
                          CookieSnapshot local,
                          DeviceBoundSessionInventory session_inventory) {
    observed_device_bound_sessions_ = std::move(session_inventory);
    // First resolve ambiguous successful pushes from the durable pending state.
    for (auto &[key, record_state] : state_.records) {
      if (!record_state.pending) {
        continue;
      }
      auto found = remote.find(key);
      if (found != remote.end() &&
          found->second.record.revision ==
              record_state.pending->target_revision &&
          found->second.payload_fingerprint ==
              record_state.pending->payload_fingerprint &&
          found->second.record.deleted == record_state.pending->deleted) {
        AcceptRemoteState(found->second,
                          record_state.pending->cookie_fingerprint);
        state_.records[key].pending.reset();
        continue;
      }
      if (found == remote.end() &&
          record_state.pending->expected_revision == 0) {
        continue;
      }
      if (found == remote.end() ||
          found->second.record.revision !=
              record_state.pending->expected_revision) {
        Block("cookie-publication-cas-conflict");
        return;
      }
    }

    std::map<std::string, RemoteCookie> apply_updates;
    for (auto &[key, remote_cookie] : remote) {
      auto state_it = state_.records.find(key);
      auto local_it = local.cookies.find(key);
      std::string local_fingerprint = local_it == local.cookies.end()
                                          ? kDeletedFingerprint
                                          : local.cookie_fingerprints.at(key);

      if (state_it == state_.records.end() ||
          state_it->second.remote_revision == 0) {
        if (remote_cookie.effective_deleted ||
            local_it == local.cookies.end() ||
            client_->enrollment_phase() == "pending") {
          apply_updates.emplace(key, remote_cookie);
        } else if (local_fingerprint == remote_cookie.cookie_fingerprint) {
          AcceptRemoteState(remote_cookie, local_fingerprint);
        } else {
          Block("uninitialized-cookie-has-local-and-remote-values");
          return;
        }
        continue;
      }

      RecordState &established = state_it->second;
      if (remote_cookie.record.revision < established.remote_revision) {
        Block("cookie-authority-revision-regressed");
        return;
      }
      if (remote_cookie.record.revision == established.remote_revision) {
        if (remote_cookie.payload_fingerprint !=
                established.remote_payload_fingerprint ||
            remote_cookie.record.deleted != established.remote_deleted) {
          Block("cookie-same-revision-payload-changed");
          return;
        }
        if (established.destination_exception &&
            local_fingerprint != established.baseline_cookie_fingerprint) {
          established.destination_exception->unverified_local_change = true;
        }
        continue;
      }
      if (local_fingerprint != established.baseline_cookie_fingerprint) {
        Block("concurrent-local-and-remote-cookie-change");
        return;
      }
      apply_updates.emplace(key, remote_cookie);
    }

    for (const auto &[key, established] : state_.records) {
      if (established.remote_revision > 0 && !remote.contains(key)) {
        Block("cookie-authority-record-disappeared");
        return;
      }
    }
    if (!SaveState()) {
      Block("cookie-state-write-failed");
      return;
    }

    if (!apply_updates.empty()) {
      BeginRemoteApply(std::move(local), std::move(apply_updates));
      return;
    }

    PublishLocalMutations(std::move(local));
  }

  void AcceptRemoteState(const RemoteCookie &remote, std::string baseline) {
    RecordState &state = state_.records[remote.record.key];
    state.remote_revision = remote.record.revision;
    state.device_id = remote.record.device_id;
    state.remote_payload_fingerprint = remote.payload_fingerprint;
    state.baseline_cookie_fingerprint = std::move(baseline);
    state.remote_deleted = remote.record.deleted;
    state.destination_exception.reset();
    state.pending.reset();
  }

  void PublishLocalMutations(CookieSnapshot local) {
    if (client_->enrollment_phase() == "pending") {
      for (const auto &[key, cookie] : local.cookies) {
        if (state_.records.contains(key)) {
          continue;
        }
        RecordState baseline;
        baseline.baseline_cookie_fingerprint =
            local.cookie_fingerprints.at(key);
        state_.records.emplace(key, std::move(baseline));
      }
      FinishVerifiedInventory();
      return;
    }

    if (!FinishVerifiedInventory()) {
      return;
    }
    std::vector<Record> mutations;
    for (const auto &[key, cookie] : local.cookies) {
      if (mutations.size() == kMaxCookiePushRecords) {
        break;
      }
      auto state_it = state_.records.find(key);
      std::string fingerprint = local.cookie_fingerprints.at(key);
      if (state_it != state_.records.end() &&
          state_it->second.destination_exception) {
        // A cookie mutation after a destination rejection is not evidence of
        // successful login. Hold it locally until a concrete browser flow can
        // verify reauthentication, or a later remote revision resolves it.
        continue;
      }
      if (state_it != state_.records.end() &&
          fingerprint == state_it->second.baseline_cookie_fingerprint) {
        continue;
      }
      int64_t expected = state_it == state_.records.end()
                             ? 0
                             : state_it->second.remote_revision;
      std::optional<std::string> payload = MakeCookiePayload(cookie);
      if (!payload) {
        Block("cookie-payload-not-fully-serializable");
        return;
      }
      Record mutation;
      mutation.kind = kCookieKind;
      mutation.key = key;
      mutation.expected_revision = expected;
      mutation.revision = expected + 1;
      mutation.payload_json = *payload;
      mutations.push_back(std::move(mutation));
      RecordState &pending_state = state_.records[key];
      pending_state.pending = PendingPublish{
          expected, expected + 1, Sha256(*payload), fingerprint, false};
    }

    for (auto &[key, record_state] : state_.records) {
      if (mutations.size() == kMaxCookiePushRecords) {
        break;
      }
      if (record_state.remote_revision == 0 || record_state.remote_deleted ||
          local.cookies.contains(key) || record_state.pending ||
          record_state.destination_exception) {
        continue;
      }
      Record mutation;
      mutation.kind = kCookieKind;
      mutation.key = key;
      mutation.expected_revision = record_state.remote_revision;
      mutation.revision = record_state.remote_revision + 1;
      mutation.deleted = true;
      mutation.payload_json = "{}";
      mutations.push_back(std::move(mutation));
      record_state.pending = PendingPublish{
          record_state.remote_revision, record_state.remote_revision + 1,
          kDeletedFingerprint, kDeletedFingerprint, true};
    }

    if (mutations.empty()) {
      reconcile_in_flight_ = false;
      return;
    }
    if (!SaveState()) {
      Block("cookie-pending-publication-write-failed");
      return;
    }
    client_->Push(
        std::move(mutations),
        base::BindOnce(&Impl::OnPushComplete, weak_factory_.GetWeakPtr()));
  }

  void OnPushComplete(bool ok, RecordsResult, std::string error) {
    if (!ok) {
      LOG(WARNING) << "Helium cookie push unconfirmed: " << error;
    }
    reconcile_in_flight_ = false;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(&Impl::Reconcile, weak_factory_.GetWeakPtr()));
  }

  bool FinishVerifiedInventory() {
    state_.verified_sequence = pending_next_seq_;
    if (!SaveState()) {
      Block("cookie-verified-state-write-failed");
      return false;
    }
    std::string error;
    if (!client_->AcknowledgeApplied(pending_next_seq_, &error)) {
      LOG(WARNING) << "Helium cookie cursor acknowledgement failed: " << error;
      reconcile_in_flight_ = false;
      return false;
    }
    if (client_->enrollment_phase() == "pending") {
      reconcile_in_flight_ = false;
      if (verified_baseline_callback_) {
        verified_baseline_callback_.Run(state_.verified_sequence);
      }
    }
    return true;
  }

  void BeginRemoteApply(CookieSnapshot before,
                        std::map<std::string, RemoteCookie> updates) {
    CookieSnapshot target = CloneSnapshot(before);
    std::set<std::string> keys;
    for (const auto &[key, remote] : updates) {
      keys.insert(key);
      if (remote.effective_deleted) {
        target.cookies.erase(key);
        target.cookie_fingerprints.erase(key);
      } else {
        target.cookies.insert_or_assign(key, *remote.cookie);
        target.cookie_fingerprints.insert_or_assign(key,
                                                    remote.cookie_fingerprint);
      }
    }
    std::vector<net::CanonicalCookie> target_cookies;
    for (const auto &[key, cookie] : target.cookies) {
      target_cookies.push_back(cookie);
    }
    std::optional<CookieSnapshot> normalized =
        BuildSnapshot(std::move(target_cookies));
    if (!normalized) {
      Block("remote-cookie-apply-preview-invalid");
      return;
    }
    target = std::move(*normalized);
    std::vector<CookieOperation> operations =
        DiffSnapshots(before, target, keys);
    if (operations.empty()) {
      for (const auto &[key, remote] : updates) {
        std::string baseline = target.cookies.contains(key)
                                   ? target.cookie_fingerprints.at(key)
                                   : kDeletedFingerprint;
        AcceptRemoteState(remote, std::move(baseline));
      }
      if (!SaveState()) {
        Block("cookie-state-write-failed-after-empty-apply");
      } else {
        reconcile_in_flight_ = false;
      }
      return;
    }
    std::optional<std::string> rollback_plaintext = MakeRollbackPayload(before);
    if (!rollback_plaintext) {
      Block("cookie-rollback-payload-invalid");
      return;
    }
    size_t set_count =
        std::ranges::count_if(operations, [](const CookieOperation &operation) {
          return operation.set;
        });
    RollbackJournal journal{"pending",          std::move(*rollback_plaintext),
                            before.fingerprint, target.fingerprint,
                            set_count,          operations.size() - set_count};
    if (!SaveRollback(journal)) {
      Block("cookie-rollback-journal-write-failed");
      return;
    }
    apply_before_ = std::move(before);
    apply_target_ = std::move(target);
    apply_updates_ = std::move(updates);
    operation_queue_ =
        std::deque<CookieOperation>(std::make_move_iterator(operations.begin()),
                                    std::make_move_iterator(operations.end()));
    active_journal_ = std::move(journal);
    restoring_ = false;
    StartNextOperation();
  }

  std::optional<std::string>
  MakeRollbackPayload(const CookieSnapshot &before) const {
    base::DictValue root;
    root.Set("format", kRollbackPayloadFormat);
    root.Set("cookies", before.serialized.Clone());
    root.Set("fingerprint", before.fingerprint);
    std::string raw;
    if (!base::JSONWriter::Write(root, &raw) ||
        raw.size() > kMaxRollbackPayloadBytes) {
      return std::nullopt;
    }
    return raw;
  }

  std::optional<CookieSnapshot>
  ParseRollbackPayload(std::string_view raw) const {
    if (raw.size() > kMaxRollbackPayloadBytes) {
      return std::nullopt;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      return std::nullopt;
    }
    const std::string *format = parsed->GetDict().FindString("format");
    if (!format || *format != kRollbackPayloadFormat) {
      return std::nullopt;
    }
    const base::ListValue *cookies = parsed->GetDict().FindList("cookies");
    const std::string *fingerprint =
        parsed->GetDict().FindString("fingerprint");
    if (!cookies || !fingerprint || cookies->size() > kMaxCookieRecords) {
      return std::nullopt;
    }
    std::vector<net::CanonicalCookie> decoded;
    for (const base::Value &value : *cookies) {
      if (!value.is_dict()) {
        return std::nullopt;
      }
      std::optional<net::CanonicalCookie> cookie =
          CookieFromValue(value.GetDict());
      if (!cookie) {
        return std::nullopt;
      }
      decoded.push_back(std::move(*cookie));
    }
    std::optional<CookieSnapshot> snapshot =
        BuildSnapshot(std::move(decoded), base::Time::Min());
    if (!snapshot || snapshot->fingerprint != *fingerprint) {
      return std::nullopt;
    }
    return snapshot;
  }

  bool SaveRollback(const RollbackJournal &journal) const {
    base::DictValue preview;
    preview.Set("before_fingerprint", journal.before_fingerprint);
    preview.Set("target_fingerprint", journal.target_fingerprint);
    preview.Set("set_count", static_cast<int>(journal.set_count));
    preview.Set("delete_count", static_cast<int>(journal.delete_count));
    base::DictValue root;
    root.Set("schema_version", kRollbackSchema);
    root.Set("status", journal.status);
    std::optional<base::Value> payload =
        base::JSONReader::Read(journal.payload_json, base::JSON_PARSE_RFC);
    if (!payload || !ParseRollbackPayload(journal.payload_json)) {
      return false;
    }
    root.Set("payload", std::move(*payload));
    root.Set("preview", std::move(preview));
    std::string raw;
    return base::JSONWriter::Write(root, &raw) &&
           WriteSecretFile(rollback_path_, raw);
  }

  std::optional<RollbackJournal> LoadRollback() const {
    if (!base::PathExists(rollback_path_)) {
      return std::nullopt;
    }
    std::string raw;
    std::optional<base::Value> parsed;
    if (!base::ReadFileToString(rollback_path_, &raw) ||
        !(parsed = base::JSONReader::Read(raw, base::JSON_PARSE_RFC)) ||
        !parsed->is_dict() ||
        parsed->GetDict().FindInt("schema_version").value_or(0) !=
            kRollbackSchema) {
      return std::nullopt;
    }
    const std::string *status = parsed->GetDict().FindString("status");
    const base::Value *payload = parsed->GetDict().Find("payload");
    const base::DictValue *preview = parsed->GetDict().FindDict("preview");
    if (!status ||
        (*status != "pending" && *status != "committed" &&
         *status != "recovered") ||
        !payload || !preview) {
      return std::nullopt;
    }
    std::string payload_json;
    if (!base::JSONWriter::Write(*payload, &payload_json) ||
        !ParseRollbackPayload(payload_json)) {
      return std::nullopt;
    }
    const std::string *before = preview->FindString("before_fingerprint");
    const std::string *target = preview->FindString("target_fingerprint");
    std::optional<int> set_count = preview->FindInt("set_count");
    std::optional<int> delete_count = preview->FindInt("delete_count");
    if (!before || !target || !set_count || *set_count < 0 || !delete_count ||
        *delete_count < 0) {
      return std::nullopt;
    }
    return RollbackJournal{*status,
                           std::move(payload_json),
                           *before,
                           *target,
                           static_cast<size_t>(*set_count),
                           static_cast<size_t>(*delete_count)};
  }

  void RecoverRollback(RollbackJournal journal) {
    std::optional<CookieSnapshot> rollback =
        ParseRollbackPayload(journal.payload_json);
    if (!rollback) {
      Block("cookie-rollback-validation-failed");
      return;
    }
    std::optional<CookieSnapshot> live_rollback =
        RefreshLiveSnapshot(*rollback);
    if (!live_rollback) {
      Block("cookie-live-rollback-snapshot-invalid");
      return;
    }
    journal.before_fingerprint = live_rollback->fingerprint;
    active_journal_ = std::move(journal);
    apply_before_ = std::move(*live_rollback);
    profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->GetAllCookies(base::BindOnce(&Impl::OnRecoveryCookies,
                                       weak_factory_.GetWeakPtr()));
  }

  void OnRecoveryCookies(const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> current = BuildSnapshot(cookies);
    if (!current) {
      Block("cookie-rollback-current-snapshot-invalid");
      return;
    }
    if (current->fingerprint == active_journal_->target_fingerprint) {
      active_journal_->status = "committed";
      if (!SaveRollback(*active_journal_)) {
        Block("cookie-rollback-finalize-failed");
        return;
      }
      active_journal_.reset();
      reconcile_in_flight_ = false;
      Reconcile();
      return;
    }
    BeginRestore(std::move(*current));
  }

  void BeginRestore(CookieSnapshot current) {
    std::optional<CookieSnapshot> live_before =
        RefreshLiveSnapshot(apply_before_);
    if (!live_before) {
      Block("cookie-rollback-refresh-failed");
      return;
    }
    apply_before_ = std::move(*live_before);
    active_journal_->before_fingerprint = apply_before_.fingerprint;
    if (!SaveRollback(*active_journal_)) {
      Block("cookie-rollback-refresh-write-failed");
      return;
    }
    std::set<std::string> keys = AllSnapshotKeys(current, apply_before_);
    std::vector<CookieOperation> operations =
        DiffSnapshots(current, apply_before_, keys);
    operation_queue_ =
        std::deque<CookieOperation>(std::make_move_iterator(operations.begin()),
                                    std::make_move_iterator(operations.end()));
    restoring_ = true;
    StartNextOperation();
  }

  void StartNextOperation() {
    if (operation_queue_.empty()) {
      VerifyOperationResult();
      return;
    }
    CookieOperation operation = std::move(operation_queue_.front());
    operation_queue_.pop_front();
    current_operation_ = operation;
    network::mojom::CookieManager *manager =
        profile_->GetDefaultStoragePartition()
            ->GetCookieManagerForBrowserProcess();
    if (operation.set) {
      if (!operation.source_url.is_valid()) {
        OnOperationFailed("invalid-cookie-source-url");
        return;
      }
      manager->SetCanonicalCookie(
          operation.cookie, operation.source_url,
          net::CookieOptions::MakeAllInclusive(),
          base::BindOnce(&Impl::OnCookieSet, weak_factory_.GetWeakPtr()));
    } else {
      manager->DeleteCanonicalCookie(
          operation.cookie,
          base::BindOnce(&Impl::OnCookieDeleted, weak_factory_.GetWeakPtr()));
    }
  }

  void OnCookieSet(net::CookieAccessResult result) {
    if (!result.status.IsInclude()) {
      if (restoring_) {
        Block("cookie-rollback-set-rejected");
        return;
      }
      rejected_record_keys_.insert(current_operation_->record_key);
      rejected_schemeful_sites_[current_operation_->record_key] =
          SchemefulSiteForCookie(current_operation_->cookie);
      OnOperationFailed("destination-set-rejected");
      return;
    }
    current_operation_.reset();
    StartNextOperation();
  }

  void OnCookieDeleted(bool) {
    // Concurrent expiry can make deletion return false while the requested
    // state is already satisfied. The post-apply snapshot is authoritative.
    current_operation_.reset();
    StartNextOperation();
  }

  void OnOperationFailed(std::string reason) {
    LOG(WARNING) << "Helium cookie operation failed: " << reason;
    if (rejected_record_keys_.empty()) {
      unscoped_apply_failure_ = true;
    }
    operation_queue_.clear();
    current_operation_.reset();
    profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->GetAllCookies(base::BindOnce(&Impl::OnFailedApplyCookies,
                                       weak_factory_.GetWeakPtr()));
  }

  void OnFailedApplyCookies(
      const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> current = BuildSnapshot(cookies);
    if (!current) {
      Block("cookie-failed-apply-snapshot-invalid");
      return;
    }
    BeginRestore(std::move(*current));
  }

  void VerifyOperationResult() {
    profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->GetAllCookies(base::BindOnce(&Impl::OnVerifiedCookies,
                                       weak_factory_.GetWeakPtr()));
  }

  void OnVerifiedCookies(const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> current = BuildSnapshot(cookies);
    if (!current) {
      Block("cookie-post-apply-snapshot-invalid");
      return;
    }
    if (restoring_) {
      if (current->fingerprint != apply_before_.fingerprint) {
        Block("cookie-rollback-verification-failed");
        return;
      }
      active_journal_->status = "recovered";
      if (!SaveRollback(*active_journal_)) {
        Block("cookie-rollback-recovery-state-write-failed");
        return;
      }
      for (const std::string &record_key : rejected_record_keys_) {
        auto remote = apply_updates_.find(record_key);
        auto site = rejected_schemeful_sites_.find(record_key);
        if (remote == apply_updates_.end() ||
            site == rejected_schemeful_sites_.end() || site->second.empty()) {
          Block("cookie-rejection-scope-invalid");
          return;
        }
        std::string baseline = current->cookies.contains(record_key)
                                   ? current->cookie_fingerprints.at(record_key)
                                   : kDeletedFingerprint;
        AcceptRemoteState(remote->second, std::move(baseline));
        DestinationException exception;
        exception.remote_revision = remote->second.record.revision;
        exception.remote_payload_fingerprint =
            remote->second.payload_fingerprint;
        exception.reason = "destination-set-rejected";
        exception.schemeful_site = site->second;
        auto observed = observed_device_bound_sessions_.find(site->second);
        if (observed != observed_device_bound_sessions_.end()) {
          exception.observed_session_ids = observed->second;
        }
        state_.records[record_key].destination_exception = exception;
      }
      if (!SaveState()) {
        Block("cookie-rejection-state-write-failed");
        return;
      }
      bool block_unscoped = unscoped_apply_failure_;
      ResetApply();
      if (block_unscoped) {
        Block("cookie-post-apply-unscoped-mismatch");
        return;
      }
      reconcile_in_flight_ = false;
      Reconcile();
      return;
    }

    if (current->fingerprint != apply_target_.fingerprint) {
      for (const auto &[key, remote] : apply_updates_) {
        bool matches = remote.effective_deleted
                           ? !current->cookies.contains(key)
                           : current->cookies.contains(key) &&
                                 current->cookie_fingerprints.at(key) ==
                                     remote.cookie_fingerprint;
        if (matches) {
          continue;
        }
        rejected_record_keys_.insert(key);
        if (remote.cookie) {
          rejected_schemeful_sites_[key] =
              SchemefulSiteForCookie(*remote.cookie);
        } else if (apply_before_.cookies.contains(key)) {
          rejected_schemeful_sites_[key] =
              SchemefulSiteForCookie(apply_before_.cookies.at(key));
        }
      }
      OnOperationFailed("cookie-post-apply-verification-mismatch");
      return;
    }
    for (const auto &[key, remote] : apply_updates_) {
      std::string baseline = current->cookies.contains(key)
                                 ? current->cookie_fingerprints.at(key)
                                 : kDeletedFingerprint;
      AcceptRemoteState(remote, std::move(baseline));
    }
    if (!SaveState()) {
      Block("cookie-state-write-failed-after-apply");
      return;
    }
    active_journal_->status = "committed";
    if (!SaveRollback(*active_journal_)) {
      Block("cookie-rollback-commit-write-failed");
      return;
    }
    ResetApply();
    reconcile_in_flight_ = false;
    Reconcile();
  }

  void ResetApply() {
    operation_queue_.clear();
    current_operation_.reset();
    apply_updates_.clear();
    apply_before_ = CookieSnapshot();
    apply_target_ = CookieSnapshot();
    active_journal_.reset();
    rejected_record_keys_.clear();
    rejected_schemeful_sites_.clear();
    observed_device_bound_sessions_.clear();
    unscoped_apply_failure_ = false;
    restoring_ = false;
  }

  bool WriteReauthSignal() const {
    base::ListValue targets;
    for (const auto &[record_key, record_state] : state_.records) {
      if (!record_state.destination_exception) {
        continue;
      }
      const DestinationException &exception =
          *record_state.destination_exception;
      base::ListValue sessions;
      for (const std::string &session_id : exception.observed_session_ids) {
        base::DictValue session;
        session.Set("schemeful_site", exception.schemeful_site);
        session.Set("session_id", session_id);
        sessions.Append(std::move(session));
      }
      base::DictValue target;
      target.Set("canonical_cookie_record_key", record_key);
      target.Set("remote_revision",
                 base::NumberToString(exception.remote_revision));
      target.Set("remote_payload_fingerprint",
                 exception.remote_payload_fingerprint);
      target.Set("schemeful_site", exception.schemeful_site);
      target.Set("origin_status", "unavailable-not-observed");
      target.Set("login_entry_status", "unavailable-not-observed");
      target.Set("unverified_local_cookie_change",
                 exception.unverified_local_change);
      target.Set("observed_site_sessions", std::move(sessions));
      targets.Append(std::move(target));
    }
    base::DictValue root;
    root.Set("schema_version", kReauthSchema);
    root.Set("action", "browser-native-password-reauthentication");
    root.Set("status", targets.empty()
                           ? "idle"
                           : "blocked-no-exact-origin-or-login-entry-evidence");
    root.Set("reason", "destination-cookie-rejected");
    root.Set("navigation_allowed", false);
    root.Set("automatic_form_submission_allowed", false);
    root.Set("targets", std::move(targets));
    std::string raw;
    return base::JSONWriter::Write(root, &raw) &&
           WriteSecretFile(reauth_signal_path_, raw);
  }

  raw_ptr<Profile> profile_;
  std::unique_ptr<HeliumSyncClient> client_;
  const base::FilePath state_path_;
  const base::FilePath rollback_path_;
  const base::FilePath reauth_signal_path_;
  BridgeState state_;
  CookieSnapshot apply_before_;
  CookieSnapshot apply_target_;
  DeviceBoundSessionInventory observed_device_bound_sessions_;
  std::map<std::string, RemoteCookie> apply_updates_;
  std::deque<CookieOperation> operation_queue_;
  std::optional<CookieOperation> current_operation_;
  std::optional<RollbackJournal> active_journal_;
  std::set<std::string> rejected_record_keys_;
  std::map<std::string, std::string> rejected_schemeful_sites_;
  bool unscoped_apply_failure_ = false;
  bool restoring_ = false;
  bool reconcile_in_flight_ = false;
  int64_t pending_next_seq_ = 0;
  base::RepeatingCallback<void(int64_t)> verified_baseline_callback_;
  base::RepeatingTimer reconcile_timer_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

HeliumCookieSyncBridge::HeliumCookieSyncBridge(
    Profile *profile, std::unique_ptr<HeliumSyncClient> client,
    base::FilePath state_path, base::FilePath rollback_path,
    base::FilePath reauth_signal_path,
    base::RepeatingCallback<void(int64_t)> verified_baseline_callback)
    : impl_(std::make_unique<Impl>(
          profile, std::move(client), std::move(state_path),
          std::move(rollback_path), std::move(reauth_signal_path),
          std::move(verified_baseline_callback))) {}

HeliumCookieSyncBridge::~HeliumCookieSyncBridge() = default;

void HeliumCookieSyncBridge::Start() { impl_->Start(); }

void HeliumCookieSyncBridge::Stop() { impl_->Stop(); }

void HeliumCookieSyncBridge::PullAndApply() { impl_->PullAndApply(); }

bool HeliumCookieSyncBridge::EnrollmentActivated(std::string *error) {
  return impl_->EnrollmentActivated(error);
}

} // namespace helium_sync
