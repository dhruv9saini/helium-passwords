// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"

#include <algorithm>
#include <deque>
#include <limits>
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
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "components/helium_sync/helium_sync_client.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace helium_sync {
namespace {

constexpr char kCookieKind[] = "cookies";
constexpr char kCookieFormat[] = "helium-cookie-domain-v1";
constexpr int kStateSchema = 1;
constexpr int kMaxCookiesPerDomain = 5000;
constexpr int kMaxCookiePayloadBytes = 2 * 1024 * 1024;
constexpr base::TimeDelta kReconcileInterval = base::Minutes(1);

struct Policy {
  std::string domain;
  std::string source;
  std::set<std::string> replicas;
  bool device_bound = false;
};

struct DomainState {
  std::string source_fingerprint;
  int source_generation = 0;
  int replica_generation = 0;
  bool needs_reauthentication = false;
};

struct RemoteDomain {
  int generation = 0;
  std::string fingerprint;
  std::vector<net::CanonicalCookie> cookies;
};

struct PendingSourceState {
  std::string fingerprint;
  int generation = 0;
};

struct CookieOperation {
  bool set = false;
  net::CanonicalCookie cookie;
  GURL source_url;
};

struct PendingReplica {
  std::string domain;
  int generation = 0;
  std::deque<CookieOperation> operations;
};

std::string CanonicalDomain(std::string value) {
  value = std::string(base::TrimWhitespaceASCII(value, base::TRIM_ALL));
  value = base::ToLowerASCII(value);
  if (base::StartsWith(value, ".")) {
    value.erase(0, 1);
  }
  return value;
}

bool DomainMatches(std::string_view cookie_domain,
                   std::string_view policy_domain) {
  std::string domain = CanonicalDomain(std::string(cookie_domain));
  return domain == policy_domain ||
         (domain.size() > policy_domain.size() &&
          base::EndsWith(domain,
                         std::string(".") + std::string(policy_domain)));
}

bool DomainsOverlap(std::string_view left, std::string_view right) {
  return DomainMatches(left, right) || DomainMatches(right, left);
}

std::string DomainRecordKey(std::string_view domain) {
  return "domain/" + std::string(domain);
}

std::string TimeToJSON(base::Time value) {
  if (value.is_null()) {
    return "0";
  }
  return base::NumberToString(
      value.ToDeltaSinceWindowsEpoch().InMicroseconds());
}

std::optional<base::Time> TimeFromJSON(const base::DictValue& value,
                                       std::string_view key) {
  const std::string* encoded = value.FindString(key);
  int64_t micros = 0;
  if (!encoded || !base::StringToInt64(*encoded, &micros)) {
    return std::nullopt;
  }
  if (micros == 0) {
    return base::Time();
  }
  return base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(micros));
}

std::optional<base::DictValue> CookieToValue(
    const net::CanonicalCookie& cookie) {
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
  if (cookie.PartitionKey()) {
    auto serialized = net::CookiePartitionKey::Serialize(cookie.PartitionKey());
    if (!serialized.has_value()) {
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

GURL SourceUrlForCookie(const net::CanonicalCookie& cookie) {
  std::string url =
      (cookie.SourceScheme() == net::CookieSourceScheme::kSecure ||
       cookie.SecureAttribute())
          ? "https://"
          : "http://";
  url += cookie.DomainWithoutDot();
  const int port = cookie.SourcePort();
  if (port > 0 && port <= 65535 &&
      !((url.starts_with("https://") && port == 443) ||
        (url.starts_with("http://") && port == 80))) {
    url += ":" + base::NumberToString(port);
  }
  url += "/";
  return GURL(url);
}

std::optional<net::CanonicalCookie> CookieFromValue(
    const base::DictValue& value) {
  const std::string* name = value.FindString("name");
  const std::string* cookie_value = value.FindString("value");
  const std::string* domain = value.FindString("domain");
  const std::string* path = value.FindString("path");
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
  if (!name || !cookie_value || !domain || !path || !creation || !expiry ||
      !last_access || !last_update || !secure || !http_only || !same_site ||
      !priority || !source_scheme || !source_port || path->empty() ||
      (*path)[0] != '/' || *same_site < -1 || *same_site > 2 || *priority < 0 ||
      *priority > 2 || *source_scheme < 0 || *source_scheme > 2 ||
      *source_port < -1 || *source_port == 0 || *source_port > 65535 ||
      (!expiry->is_null() && *expiry <= *creation)) {
    return std::nullopt;
  }

  std::optional<net::CookiePartitionKey> partition_key;
  if (const base::DictValue* partition = value.FindDict("partition_key")) {
    const std::string* top_level_site = partition->FindString("top_level_site");
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

  const net::CookieSourceScheme scheme =
      static_cast<net::CookieSourceScheme>(*source_scheme);
  std::string source = (scheme == net::CookieSourceScheme::kSecure || *secure)
                           ? "https://"
                           : "http://";
  source += CanonicalDomain(*domain) + "/";
  GURL source_url(source);
  if (!source_url.is_valid()) {
    return std::nullopt;
  }
  std::unique_ptr<net::CanonicalCookie> cookie =
      net::CanonicalCookie::CreateSanitizedCookie(
          source_url, *name, *cookie_value, *domain, *path, *creation, *expiry,
          *last_access, *secure, *http_only,
          static_cast<net::CookieSameSite>(*same_site),
          static_cast<net::CookiePriority>(*priority), partition_key,
          /*status=*/nullptr);
  if (!cookie) {
    return std::nullopt;
  }
  cookie->SetSourceScheme(scheme);
  cookie->SetSourcePort(*source_port);
  if (!SourceUrlForCookie(*cookie).is_valid()) {
    return std::nullopt;
  }
  return std::move(*cookie);
}

std::optional<std::string> CookieIdentity(const net::CanonicalCookie& cookie) {
  std::string partition = "unpartitioned";
  if (cookie.PartitionKey()) {
    auto serialized = net::CookiePartitionKey::Serialize(cookie.PartitionKey());
    if (!serialized.has_value()) {
      return std::nullopt;
    }
    partition = serialized->TopLevelSite() + "\0" +
                (serialized->has_cross_site_ancestor() ? "1" : "0");
  }
  return partition + "\0" + cookie.Domain() + "\0" + cookie.Path() + "\0" +
         cookie.Name() + "\0" +
         base::NumberToString(static_cast<int>(cookie.SourceScheme())) + "\0" +
         base::NumberToString(cookie.SourcePort());
}

std::optional<base::ListValue> CookiesToValue(
    std::vector<net::CanonicalCookie> cookies) {
  std::map<std::string, net::CanonicalCookie> by_identity;
  for (net::CanonicalCookie& cookie : cookies) {
    if (cookie.IsExpired(base::Time::Now())) {
      continue;
    }
    std::optional<std::string> identity = CookieIdentity(cookie);
    if (!identity) {
      return std::nullopt;
    }
    by_identity.insert_or_assign(std::move(*identity), std::move(cookie));
  }
  if (by_identity.size() > kMaxCookiesPerDomain) {
    return std::nullopt;
  }
  base::ListValue out;
  for (const auto& [identity, cookie] : by_identity) {
    std::optional<base::DictValue> value = CookieToValue(cookie);
    if (!value) {
      return std::nullopt;
    }
    out.Append(std::move(*value));
  }
  return out;
}

std::optional<std::string> FingerprintCookies(const base::ListValue& cookies) {
  base::ListValue mutation_fields;
  for (const base::Value& item : cookies) {
    if (!item.is_dict()) {
      return std::nullopt;
    }
    base::DictValue cookie = item.GetDict().Clone();
    // Reads update access metadata and replicas cannot recreate update time.
    // They are retained in the payload for recovery but are not rotations.
    cookie.Remove("creation");
    cookie.Remove("last_access");
    cookie.Remove("last_update");
    mutation_fields.Append(std::move(cookie));
  }
  std::string raw;
  if (!base::JSONWriter::Write(mutation_fields, &raw)) {
    return std::nullopt;
  }
  return base::HexEncodeLower(crypto::SHA256HashString(raw));
}

std::optional<std::string> MakeDomainPayload(const Policy& policy,
                                             int generation,
                                             base::ListValue cookies) {
  base::DictValue payload;
  payload.Set("format", kCookieFormat);
  payload.Set("domain", policy.domain);
  payload.Set("source_device", policy.source);
  payload.Set("mode", policy.device_bound ? "device-bound" : "portable");
  payload.Set("generation", generation);
  payload.Set("cookies", std::move(cookies));
  std::string raw;
  if (!base::JSONWriter::Write(payload, &raw) ||
      raw.size() > kMaxCookiePayloadBytes) {
    return std::nullopt;
  }
  return raw;
}

std::optional<RemoteDomain> ParseRemoteDomain(const Policy& policy,
                                              const base::DictValue& payload) {
  const std::string* format = payload.FindString("format");
  const std::string* domain = payload.FindString("domain");
  const std::string* source = payload.FindString("source_device");
  const std::string* mode = payload.FindString("mode");
  std::optional<int> generation = payload.FindInt("generation");
  const base::ListValue* cookies = payload.FindList("cookies");
  if (!format || *format != kCookieFormat || !domain ||
      CanonicalDomain(*domain) != policy.domain || !source ||
      *source != policy.source || !mode ||
      *mode != (policy.device_bound ? "device-bound" : "portable") ||
      !generation || *generation <= 0 || !cookies ||
      cookies->size() > kMaxCookiesPerDomain ||
      (policy.device_bound && !cookies->empty())) {
    return std::nullopt;
  }
  RemoteDomain out;
  out.generation = *generation;
  for (const base::Value& item : *cookies) {
    if (!item.is_dict()) {
      return std::nullopt;
    }
    std::optional<net::CanonicalCookie> cookie =
        CookieFromValue(item.GetDict());
    if (!cookie || !DomainMatches(cookie->Domain(), policy.domain) ||
        cookie->IsExpired(base::Time::Now())) {
      return std::nullopt;
    }
    out.cookies.push_back(std::move(*cookie));
  }
  std::optional<base::ListValue> normalized = CookiesToValue(out.cookies);
  if (!normalized) {
    return std::nullopt;
  }
  std::optional<std::string> fingerprint = FingerprintCookies(*normalized);
  if (!fingerprint) {
    return std::nullopt;
  }
  out.fingerprint = std::move(*fingerprint);
  return out;
}

}  // namespace

class HeliumCookieSyncBridge::Impl {
 public:
  Impl(Profile* profile,
       std::unique_ptr<HeliumSyncClient> client,
       std::string device_name,
       base::FilePath policies_path,
       base::FilePath state_path)
      : profile_(profile),
        client_(std::move(client)),
        device_name_(std::move(device_name)),
        policies_path_(std::move(policies_path)),
        state_path_(std::move(state_path)) {}

  ~Impl() { Stop(); }

  void Start() {
    if (!profile_ || !client_ || policies_path_.empty() || !LoadPolicies()) {
      LOG(WARNING) << "Helium cookie sync inactive: cookie policy is missing "
                      "or invalid";
      return;
    }
    LoadState();
    reconcile_timer_.Start(
        FROM_HERE, kReconcileInterval,
        base::BindRepeating(&Impl::Reconcile, weak_factory_.GetWeakPtr()));
    Reconcile();
  }

  void Stop() {
    reconcile_timer_.Stop();
    weak_factory_.InvalidateWeakPtrs();
    reconcile_in_flight_ = false;
    source_push_in_flight_ = false;
    replica_apply_in_flight_ = false;
    pending_replicas_.clear();
  }

 private:
  bool LoadPolicies() {
    std::string raw;
    if (!base::ReadFileToString(policies_path_, &raw)) {
      return false;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      return false;
    }
    const base::ListValue* list = parsed->GetDict().FindList("cookie_policies");
    if (!list || list->empty()) {
      return false;
    }
    std::vector<Policy> loaded;
    for (const base::Value& item : *list) {
      if (!item.is_dict()) {
        return false;
      }
      const base::DictValue& value = item.GetDict();
      const std::string* domain_value = value.FindString("domain");
      const std::string* source = value.FindString("source");
      const std::string* mode = value.FindString("mode");
      const base::ListValue* replicas = value.FindList("replicas");
      if (!domain_value || !source || source->empty() || !mode || !replicas ||
          (*mode != "portable" && *mode != "device-bound")) {
        return false;
      }
      Policy policy;
      policy.domain = CanonicalDomain(*domain_value);
      policy.source = *source;
      policy.device_bound = *mode == "device-bound";
      GURL domain_url("https://" + policy.domain + "/");
      if (policy.domain.empty() || !domain_url.is_valid() ||
          domain_url.host() != policy.domain) {
        return false;
      }
      for (const base::Value& replica : *replicas) {
        if (!replica.is_string() || replica.GetString().empty() ||
            replica.GetString() == policy.source ||
            !policy.replicas.insert(replica.GetString()).second) {
          return false;
        }
      }
      for (const Policy& existing : loaded) {
        if (DomainsOverlap(existing.domain, policy.domain)) {
          return false;
        }
      }
      loaded.push_back(std::move(policy));
    }
    policies_ = std::move(loaded);
    return true;
  }

  void LoadState() {
    state_.clear();
    if (!base::PathExists(state_path_)) {
      return;
    }
    std::string raw;
    std::optional<base::Value> parsed;
    if (!base::ReadFileToString(state_path_, &raw) ||
        !(parsed = base::JSONReader::Read(raw, base::JSON_PARSE_RFC)) ||
        !parsed->is_dict() ||
        parsed->GetDict().FindInt("schema_version").value_or(0) !=
            kStateSchema) {
      LOG(WARNING) << "Helium cookie sync ignored invalid state";
      return;
    }
    const base::DictValue* domains = parsed->GetDict().FindDict("domains");
    if (!domains) {
      return;
    }
    for (const auto [domain, value] : *domains) {
      if (!value.is_dict()) {
        state_.clear();
        return;
      }
      DomainState item;
      if (const std::string* fingerprint =
              value.GetDict().FindString("source_fingerprint")) {
        item.source_fingerprint = *fingerprint;
      }
      item.source_generation =
          value.GetDict().FindInt("source_generation").value_or(0);
      item.replica_generation =
          value.GetDict().FindInt("replica_generation").value_or(0);
      item.needs_reauthentication =
          value.GetDict().FindBool("needs_reauthentication").value_or(false);
      if (item.source_generation < 0 || item.replica_generation < 0) {
        state_.clear();
        return;
      }
      state_[domain] = std::move(item);
    }
  }

  bool SaveState() const {
    if (!base::CreateDirectory(state_path_.DirName())) {
      return false;
    }
    base::DictValue domains;
    for (const auto& [domain, item] : state_) {
      base::DictValue value;
      value.Set("source_fingerprint", item.source_fingerprint);
      value.Set("source_generation", item.source_generation);
      value.Set("replica_generation", item.replica_generation);
      value.Set("needs_reauthentication", item.needs_reauthentication);
      domains.Set(domain, std::move(value));
    }
    base::DictValue root;
    root.Set("schema_version", kStateSchema);
    root.Set("domains", std::move(domains));
    std::string raw;
    return base::JSONWriter::Write(root, &raw) &&
           base::ImportantFileWriter::WriteFileAtomically(state_path_, raw,
                                                          "HeliumSync");
  }

  void Reconcile() {
    if (reconcile_in_flight_) {
      return;
    }
    reconcile_in_flight_ = true;
    client_->Latest(
        {kCookieKind}, /*include_deleted=*/false,
        base::BindOnce(&Impl::OnLatest, weak_factory_.GetWeakPtr()));
  }

  void OnLatest(bool ok, std::string response, std::string error) {
    if (!ok) {
      LOG(WARNING) << "Helium cookie pull failed: " << error;
      reconcile_in_flight_ = false;
      return;
    }
    std::optional<std::map<std::string, RemoteDomain>> remote =
        ParseRemote(std::move(response));
    if (!remote) {
      LOG(WARNING) << "Helium cookie pull rejected malformed authority data";
      reconcile_in_flight_ = false;
      return;
    }
    profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->GetAllCookies(base::BindOnce(
            &Impl::OnCookies, weak_factory_.GetWeakPtr(), std::move(*remote)));
  }

  std::optional<std::map<std::string, RemoteDomain>> ParseRemote(
      std::string response) {
    std::optional<base::Value> root =
        base::JSONReader::Read(response, base::JSON_PARSE_RFC);
    if (!root || !root->is_dict()) {
      return std::nullopt;
    }
    const base::ListValue* records = root->GetDict().FindList("records");
    if (!records) {
      return std::nullopt;
    }
    std::map<std::string, RemoteDomain> out;
    std::map<std::string, const Policy*> by_key;
    for (const Policy& policy : policies_) {
      by_key[DomainRecordKey(policy.domain)] = &policy;
    }
    for (const base::Value& item : *records) {
      if (!item.is_dict()) {
        return std::nullopt;
      }
      const base::DictValue& record = item.GetDict();
      const std::string* kind = record.FindString("kind");
      const std::string* key = record.FindString("key");
      if (!kind || *kind != kCookieKind || !key || !by_key.contains(*key)) {
        continue;
      }
      const Policy& policy = *by_key[*key];
      const std::string* origin = record.FindString("origin_device");
      const base::DictValue* payload = record.FindDict("payload");
      if (!origin || *origin != policy.source || !payload ||
          record.FindBool("deleted").value_or(false)) {
        return std::nullopt;
      }
      std::optional<RemoteDomain> domain = ParseRemoteDomain(policy, *payload);
      if (!domain || !out.emplace(policy.domain, std::move(*domain)).second) {
        return std::nullopt;
      }
    }
    return out;
  }

  void OnCookies(std::map<std::string, RemoteDomain> remote,
                 const std::vector<net::CanonicalCookie>& all_cookies) {
    std::vector<Record> source_records;
    std::map<std::string, PendingSourceState> source_state;
    pending_replicas_.clear();
    for (const Policy& policy : policies_) {
      auto remote_item = remote.find(policy.domain);
      if (policy.source == device_name_) {
        std::vector<net::CanonicalCookie> local;
        if (!policy.device_bound) {
          for (const net::CanonicalCookie& cookie : all_cookies) {
            if (DomainMatches(cookie.Domain(), policy.domain)) {
              local.push_back(cookie);
            }
          }
        }
        std::optional<base::ListValue> cookies = CookiesToValue(local);
        std::optional<std::string> fingerprint =
            cookies ? FingerprintCookies(*cookies) : std::nullopt;
        if (!cookies || !fingerprint) {
          LOG(WARNING) << "Helium cookie source retained prior generation for "
                       << policy.domain;
          continue;
        }
        if (remote_item != remote.end() &&
            remote_item->second.fingerprint == *fingerprint) {
          DomainState& item = state_[policy.domain];
          item.source_fingerprint = *fingerprint;
          item.source_generation = remote_item->second.generation;
          continue;
        }
        const int previous = remote_item == remote.end()
                                 ? state_[policy.domain].source_generation
                                 : remote_item->second.generation;
        if (previous == std::numeric_limits<int>::max()) {
          LOG(WARNING) << "Helium cookie generation overflow for "
                       << policy.domain;
          continue;
        }
        const int generation = previous + 1;
        std::optional<std::string> payload =
            MakeDomainPayload(policy, generation, std::move(*cookies));
        if (!payload) {
          continue;
        }
        Record record;
        record.kind = kCookieKind;
        record.key = DomainRecordKey(policy.domain);
        record.origin_device = device_name_;
        record.payload_json = std::move(*payload);
        source_records.push_back(std::move(record));
        source_state[policy.domain] = {*fingerprint, generation};
        continue;
      }

      if (!policy.replicas.contains(device_name_) ||
          remote_item == remote.end() ||
          state_[policy.domain].replica_generation >=
              remote_item->second.generation) {
        continue;
      }
      if (policy.device_bound) {
        DomainState& item = state_[policy.domain];
        item.replica_generation = remote_item->second.generation;
        item.needs_reauthentication = true;
        continue;
      }
      PendingReplica pending;
      pending.domain = policy.domain;
      pending.generation = remote_item->second.generation;
      bool pending_valid = true;
      std::set<std::string> remote_identities;
      for (const net::CanonicalCookie& cookie : remote_item->second.cookies) {
        std::optional<std::string> identity = CookieIdentity(cookie);
        if (!identity) {
          pending_valid = false;
          break;
        }
        remote_identities.insert(*identity);
      }
      for (const net::CanonicalCookie& cookie : all_cookies) {
        if (!DomainMatches(cookie.Domain(), policy.domain)) {
          continue;
        }
        std::optional<std::string> identity = CookieIdentity(cookie);
        if (!identity) {
          pending_valid = false;
          break;
        }
        if (!remote_identities.contains(*identity)) {
          pending.operations.push_back({false, cookie, GURL()});
        }
      }
      for (const net::CanonicalCookie& cookie : remote_item->second.cookies) {
        GURL source_url = SourceUrlForCookie(cookie);
        if (!source_url.is_valid()) {
          pending_valid = false;
          break;
        }
        pending.operations.push_back({true, cookie, std::move(source_url)});
      }
      if (pending_valid) {
        pending_replicas_.push_back(std::move(pending));
      } else {
        LOG(WARNING) << "Helium cookie replica retained prior generation for "
                     << policy.domain;
      }
    }
    SaveState();

    source_push_in_flight_ = !source_records.empty();
    if (source_push_in_flight_) {
      client_->Push(
          std::move(source_records),
          base::BindOnce(&Impl::OnSourcePush, weak_factory_.GetWeakPtr(),
                         std::move(source_state)));
    }
    replica_apply_in_flight_ = !pending_replicas_.empty();
    if (replica_apply_in_flight_) {
      StartNextReplica();
    }
    MaybeFinish();
  }

  void OnSourcePush(std::map<std::string, PendingSourceState> pending,
                    bool ok,
                    std::string error) {
    source_push_in_flight_ = false;
    if (!ok) {
      LOG(WARNING) << "Helium cookie source push failed: " << error;
      MaybeFinish();
      return;
    }
    for (const auto& [domain, update] : pending) {
      DomainState& item = state_[domain];
      item.source_fingerprint = update.fingerprint;
      item.source_generation = update.generation;
    }
    SaveState();
    MaybeFinish();
  }

  void StartNextReplica() {
    if (pending_replicas_.empty()) {
      replica_apply_in_flight_ = false;
      MaybeFinish();
      return;
    }
    if (pending_replicas_.front().operations.empty()) {
      CompleteReplica();
      return;
    }
    CookieOperation operation =
        std::move(pending_replicas_.front().operations.front());
    pending_replicas_.front().operations.pop_front();
    network::mojom::CookieManager* manager =
        profile_->GetDefaultStoragePartition()
            ->GetCookieManagerForBrowserProcess();
    if (operation.set) {
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
      FailReplica("set rejected");
      return;
    }
    StartNextReplica();
  }

  void OnCookieDeleted(bool) {
    // A concurrent expiry makes deletion return false but already satisfies
    // the replica generation.
    StartNextReplica();
  }

  void CompleteReplica() {
    PendingReplica completed = std::move(pending_replicas_.front());
    pending_replicas_.pop_front();
    DomainState& item = state_[completed.domain];
    item.replica_generation = completed.generation;
    item.needs_reauthentication = false;
    SaveState();
    StartNextReplica();
  }

  void FailReplica(std::string_view reason) {
    LOG(WARNING) << "Helium cookie replica apply failed for "
                 << pending_replicas_.front().domain << ": " << reason;
    pending_replicas_.clear();
    replica_apply_in_flight_ = false;
    MaybeFinish();
  }

  void MaybeFinish() {
    if (!source_push_in_flight_ && !replica_apply_in_flight_) {
      reconcile_in_flight_ = false;
    }
  }

  raw_ptr<Profile> profile_;
  std::unique_ptr<HeliumSyncClient> client_;
  const std::string device_name_;
  const base::FilePath policies_path_;
  const base::FilePath state_path_;
  std::vector<Policy> policies_;
  std::map<std::string, DomainState> state_;
  std::deque<PendingReplica> pending_replicas_;
  bool reconcile_in_flight_ = false;
  bool source_push_in_flight_ = false;
  bool replica_apply_in_flight_ = false;
  base::RepeatingTimer reconcile_timer_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

HeliumCookieSyncBridge::HeliumCookieSyncBridge(
    Profile* profile,
    std::unique_ptr<HeliumSyncClient> client,
    std::string device_name,
    base::FilePath policies_path,
    base::FilePath state_path)
    : impl_(std::make_unique<Impl>(profile,
                                   std::move(client),
                                   std::move(device_name),
                                   std::move(policies_path),
                                   std::move(state_path))) {}

HeliumCookieSyncBridge::~HeliumCookieSyncBridge() = default;

void HeliumCookieSyncBridge::Start() {
  impl_->Start();
}

void HeliumCookieSyncBridge::Stop() {
  impl_->Stop();
}

}  // namespace helium_sync
