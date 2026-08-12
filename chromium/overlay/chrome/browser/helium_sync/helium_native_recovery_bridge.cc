// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_native_recovery_bridge.h"

#include <algorithm>
#include <cstdint>
#include <deque>
#include <initializer_list>
#include <map>
#include <optional>
#include <ranges>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/numerics/safe_conversions.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_store/password_store_change.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/sync/password_proto_utils.h"
#include "components/sync/protocol/password_specifics.pb.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_ANDROID)
#include "base/android/apk_info.h"
#endif

namespace helium_sync {
namespace {

constexpr char kPasswordRestoreSwitch[] =
    "helium-restore-disposable-native-passwords";
constexpr char kCookieRestoreSwitch[] =
    "helium-restore-disposable-native-cookies";
constexpr char kTabRestoreSwitch[] = "helium-restore-disposable-tabs";
constexpr char kRootMarker[] = ".helium-native-recovery-root-v1";
constexpr char kRootMarkerContents[] = "helium-native-recovery-root-v1\n";
constexpr char kProfileMarker[] =
    ".helium-native-recovery-disposable-profile-v1";
constexpr char kProfileMarkerContents[] =
    "helium-native-recovery-disposable-profile-v1\n";
constexpr char kPasswordSnapshot[] = "passwords.current.json";
constexpr char kCookieSnapshot[] = "cookies.current.json";
constexpr char kReceipt[] =
    "helium-sync/native-recovery-receipt-v1.json";
constexpr char kPasswordKind[] = "passwords";
constexpr char kCookieKind[] = "cookies";
constexpr char kPasswordFormat[] =
    "chromium-password-specifics-neutral-v1";
constexpr char kCookieFormat[] = "chromium-cookie-manager-neutral-v1";
constexpr char kPasswordPayloadFormat[] =
    "chromium-password-specifics-data-v1";
constexpr char kPasswordIdentityPrefix[] = "credential/v2/";
constexpr int kSnapshotSchema = 1;
constexpr int kReceiptSchema = 1;
constexpr size_t kMaxRecords = 50000;
constexpr size_t kMaxSnapshotBytes = 64 * 1024 * 1024;
constexpr base::TimeDelta kCaptureInterval = base::Minutes(2);

using Credential = password_manager::StoredCredential;

enum class RestoreKind { kNone, kPasswords, kCookies, kInvalid };
enum class PasswordRead { kNone, kCapture, kRestoreInitial, kRestoreVerify };

struct PasswordSnapshot {
  std::vector<Credential> credentials;
  size_t record_count = 0;
  std::string source_device;
  std::string records_sha256;
  std::string state_sha256;
  std::string file_sha256;
};

struct CookieSnapshot {
  std::map<std::string, net::CanonicalCookie> cookies;
  std::map<std::string, std::string> cookie_fingerprints;
  base::ListValue records;
  std::string records_sha256;
  std::string state_sha256;
};

std::string Sha256(std::string_view value) {
  return base::HexEncodeLower(crypto::SHA256HashString(value));
}

bool IsLowerHexDigest(std::string_view value) {
  return value.size() == 64 && std::ranges::all_of(value, [](char c) {
           return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
         });
}

bool HasExactKeys(const base::DictValue &value,
                  std::initializer_list<std::string_view> keys) {
  if (value.size() != keys.size()) {
    return false;
  }
  return std::ranges::all_of(keys,
                             [&value](std::string_view key) {
                               return value.Find(key) != nullptr;
                             });
}

std::string CaptureTime() {
  return base::NumberToString(
      base::Time::Now().ToDeltaSinceWindowsEpoch().InMicroseconds());
}

bool IsValidCaptureTime(std::string_view value) {
  int64_t parsed = 0;
  return base::StringToInt64(value, &parsed) && parsed > 0;
}

bool IsValidDevice(std::string_view value) {
  return value == "d" || value == "da" || value == "oneplus" ||
         value == "fixture";
}

bool PrivateRegularFile(const base::FilePath &path, size_t maximum,
                        std::string *contents) {
  const std::optional<int64_t> size = base::GetFileSize(path);
  if (!path.IsAbsolute() || base::MakeAbsoluteFilePath(path) != path ||
      base::IsLink(path) || !base::PathExists(path) ||
      !size || *size < 1 ||
      *size > base::checked_cast<int64_t>(maximum) ||
      !base::ReadFileToString(path, contents)) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  int permissions = 0;
  if (!base::GetPosixFilePermissions(path, &permissions) ||
      permissions != 0600) {
    contents->clear();
    return false;
  }
#endif
  return true;
}

bool PrivateDirectory(const base::FilePath &path) {
  if (!path.IsAbsolute() || base::MakeAbsoluteFilePath(path) != path ||
      base::IsLink(path) || !base::DirectoryExists(path)) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  int permissions = 0;
  if (!base::GetPosixFilePermissions(path, &permissions) ||
      permissions != 0700) {
    return false;
  }
#endif
  return true;
}

bool HasExactPrivateMarker(const base::FilePath &directory, const char *leaf,
                           std::string_view expected) {
  std::string marker;
  return PrivateRegularFile(directory.AppendASCII(leaf), expected.size(),
                            &marker) &&
         marker == expected;
}

bool WriteSecretFile(const base::FilePath &path, std::string_view contents) {
  if (!base::ImportantFileWriter::WriteFileAtomically(path, contents,
                                                       "HeliumRecovery")) {
    return false;
  }
#if BUILDFLAG(IS_POSIX)
  return base::SetPosixFilePermissions(path, 0600);
#else
  return true;
#endif
}

void AppendU32(uint32_t value, std::string *out) {
  out->push_back(static_cast<char>((value >> 24) & 0xff));
  out->push_back(static_cast<char>((value >> 16) & 0xff));
  out->push_back(static_cast<char>((value >> 8) & 0xff));
  out->push_back(static_cast<char>(value & 0xff));
}

void AppendStringField(std::string_view value, std::string *out) {
  AppendU32(base::checked_cast<uint32_t>(value.size()), out);
  out->append(value);
}

void AppendUTF16Field(std::u16string_view value, std::string *out) {
  AppendU32(base::checked_cast<uint32_t>(value.size()), out);
  for (char16_t code_unit : value) {
    out->push_back(static_cast<char>((code_unit >> 8) & 0xff));
    out->push_back(static_cast<char>(code_unit & 0xff));
  }
}

std::string PasswordIdentityMaterial(const Credential &credential) {
  std::string material("helium-password-identity-v2\0", 28);
  AppendStringField(credential.url.spec(), &material);
  AppendUTF16Field(credential.username_element, &material);
  AppendUTF16Field(credential.username_value, &material);
  AppendUTF16Field(credential.password_element, &material);
  AppendStringField(credential.signon_realm, &material);
  return material;
}

std::string PasswordRecordKey(const Credential &credential) {
  return std::string(kPasswordIdentityPrefix) +
         Sha256(PasswordIdentityMaterial(credential));
}

std::optional<base::DictValue>
PasswordPayloadValue(const Credential &credential) {
  sync_pb::PasswordSpecificsData specifics =
      password_manager::SpecificsDataFromStoredCredential(
          credential, /*base_password_data=*/{});
  std::string serialized;
  if (!specifics.SerializeToString(&serialized)) {
    return std::nullopt;
  }
  base::DictValue payload;
  payload.Set("format", kPasswordPayloadFormat);
  payload.Set("password_specifics_data_b64", base::Base64Encode(serialized));
  return payload;
}

std::optional<Credential>
PasswordFromPayload(const base::DictValue &payload) {
  const std::string *format = payload.FindString("format");
  if (!HasExactKeys(payload,
                    {"format", "password_specifics_data_b64"}) ||
      !format || *format != kPasswordPayloadFormat) {
    return std::nullopt;
  }
  const std::string *encoded =
      payload.FindString("password_specifics_data_b64");
  std::string serialized;
  if (!encoded || !base::Base64Decode(*encoded, &serialized)) {
    return std::nullopt;
  }
  sync_pb::PasswordSpecificsData specifics;
  if (!specifics.ParseFromString(serialized)) {
    return std::nullopt;
  }
  Credential credential =
      password_manager::StoredCredentialFromSpecifics(specifics);
  credential.in_store = password_manager::PasswordForm::Store::kProfileStore;
  if (credential.signon_realm.empty() ||
      (specifics.has_origin() && !specifics.origin().empty() &&
       !credential.url.is_valid())) {
    return std::nullopt;
  }
  return credential;
}

std::optional<base::ListValue>
PasswordRecords(const password_manager::LoginsResult &credentials) {
  std::map<std::string, base::DictValue> records;
  std::map<std::string, std::string> identities;
  for (const Credential &credential : credentials) {
    std::string key = PasswordRecordKey(credential);
    std::string identity = PasswordIdentityMaterial(credential);
    if ((identities.contains(key) && identities.at(key) != identity) ||
        records.contains(key)) {
      return std::nullopt;
    }
    std::optional<base::DictValue> payload =
        PasswordPayloadValue(credential);
    if (!payload) {
      return std::nullopt;
    }
    identities.emplace(key, std::move(identity));
    base::DictValue record;
    record.Set("key", key);
    record.Set("payload", std::move(*payload));
    records.emplace(std::move(key), std::move(record));
  }
  if (records.size() > kMaxRecords) {
    return std::nullopt;
  }
  base::ListValue result;
  for (auto &[key, record] : records) {
    result.Append(std::move(record));
  }
  return result;
}

std::optional<std::string> ValueSha256(const base::Value &value) {
  std::string raw;
  if (!base::JSONWriter::Write(value, &raw)) {
    return std::nullopt;
  }
  return Sha256(raw);
}

std::optional<std::string>
PasswordStateSha256(const password_manager::LoginsResult &credentials) {
  std::map<std::string, std::string> fingerprints;
  for (const Credential &credential : credentials) {
    std::optional<base::DictValue> payload =
        PasswordPayloadValue(credential);
    std::optional<std::string> payload_sha =
        payload ? ValueSha256(base::Value(payload->Clone())) : std::nullopt;
    std::string key = PasswordRecordKey(credential);
    if (!payload_sha || !fingerprints.emplace(key, *payload_sha).second) {
      return std::nullopt;
    }
  }
  std::string material;
  for (const auto &[key, fingerprint] : fingerprints) {
    material += key + "\0" + fingerprint + "\n";
  }
  return Sha256(material);
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
  const base::Value *partition_value = value.Find("partition_key");
  if (partition_value && !partition_value->is_dict()) {
    return std::nullopt;
  }
  const size_t expected_size = partition_value ? 16 : 15;
  if (value.size() != expected_size) {
    return std::nullopt;
  }
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
    if (!HasExactKeys(*partition,
                      {"top_level_site", "has_cross_site_ancestor"})) {
      return std::nullopt;
    }
    const std::string *site = partition->FindString("top_level_site");
    std::optional<bool> cross_site =
        partition->FindBool("has_cross_site_ancestor");
    if (!site || !cross_site) {
      return std::nullopt;
    }
    auto parsed =
        net::CookiePartitionKey::FromUntrustedInput(*site, *cross_site);
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
  return cookie ? std::optional<net::CanonicalCookie>(std::move(*cookie))
                : std::nullopt;
}

std::optional<std::string> CookieIdentity(
    const net::CanonicalCookie &cookie) {
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

std::optional<std::string> CookieRecordKey(
    const net::CanonicalCookie &cookie) {
  std::optional<std::string> identity = CookieIdentity(cookie);
  return identity ? std::optional<std::string>(Sha256(*identity))
                  : std::nullopt;
}

std::optional<std::string> CookieFingerprint(
    const net::CanonicalCookie &cookie) {
  std::optional<base::DictValue> value = CookieToValue(cookie);
  if (!value) {
    return std::nullopt;
  }
  value->Remove("creation");
  value->Remove("last_access");
  value->Remove("last_update");
  return ValueSha256(base::Value(std::move(*value)));
}

std::optional<CookieSnapshot>
BuildCookieSnapshot(std::vector<net::CanonicalCookie> cookies,
                    base::Time now = base::Time::Now()) {
  CookieSnapshot result;
  std::map<std::string, base::DictValue> values;
  for (net::CanonicalCookie &cookie : cookies) {
    if (cookie.IsExpired(now)) {
      continue;
    }
    std::optional<std::string> key = CookieRecordKey(cookie);
    std::optional<std::string> fingerprint = CookieFingerprint(cookie);
    std::optional<base::DictValue> value = CookieToValue(cookie);
    if (!key || !fingerprint || !value || result.cookies.contains(*key)) {
      return std::nullopt;
    }
    result.cookie_fingerprints.emplace(*key, *fingerprint);
    values.emplace(*key, std::move(*value));
    result.cookies.emplace(*key, std::move(cookie));
  }
  if (result.cookies.size() > kMaxRecords) {
    return std::nullopt;
  }
  std::string state_material;
  for (auto &[key, value] : values) {
    base::DictValue record;
    record.Set("key", key);
    record.Set("cookie", std::move(value));
    result.records.Append(std::move(record));
    state_material += key + "\0" + result.cookie_fingerprints.at(key) + "\n";
  }
  std::optional<std::string> records_sha =
      ValueSha256(base::Value(result.records.Clone()));
  if (!records_sha) {
    return std::nullopt;
  }
  result.records_sha256 = std::move(*records_sha);
  result.state_sha256 = Sha256(state_material);
  return result;
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

std::optional<std::string> MakeSnapshotEnvelope(
    std::string_view kind, std::string_view format,
    std::string_view source_device, const base::ListValue &records,
    std::string_view records_sha256, std::string_view state_sha256) {
  base::DictValue root;
  root.Set("schema_version", kSnapshotSchema);
  root.Set("kind", kind);
  root.Set("format", format);
  root.Set("source_device", source_device);
  root.Set("captured_at_windows_us", CaptureTime());
  root.Set("record_count", base::checked_cast<int>(records.size()));
  root.Set("records", records.Clone());
  root.Set("records_sha256", records_sha256);
  root.Set("state_sha256", state_sha256);
  std::string raw;
  if (!base::JSONWriter::Write(root, &raw) ||
      raw.size() > kMaxSnapshotBytes) {
    return std::nullopt;
  }
  return raw;
}

std::optional<base::DictValue> ParseEnvelope(
    std::string_view raw, std::string_view expected_kind,
    std::string_view expected_format, std::string *source_device,
    std::string *records_sha256, std::string *state_sha256) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue &root = parsed->GetDict();
  const std::string *kind = root.FindString("kind");
  const std::string *format = root.FindString("format");
  if (!HasExactKeys(root,
                    {"schema_version", "kind", "format", "source_device",
                     "captured_at_windows_us", "record_count", "records",
                     "records_sha256", "state_sha256"}) ||
      root.FindInt("schema_version").value_or(0) != kSnapshotSchema ||
      !kind || *kind != expected_kind || !format ||
      *format != expected_format) {
    return std::nullopt;
  }
  const std::string *device = root.FindString("source_device");
  const std::string *captured = root.FindString("captured_at_windows_us");
  std::optional<int> count = root.FindInt("record_count");
  const base::ListValue *records = root.FindList("records");
  const std::string *records_sha = root.FindString("records_sha256");
  const std::string *state_sha = root.FindString("state_sha256");
  std::optional<std::string> actual_records_sha =
      records ? ValueSha256(base::Value(records->Clone())) : std::nullopt;
  if (!device || !IsValidDevice(*device) || !captured ||
      !IsValidCaptureTime(*captured) || !count || *count < 0 || !records ||
      records->size() != base::checked_cast<size_t>(*count) ||
      records->size() > kMaxRecords || !records_sha || !state_sha ||
      !IsLowerHexDigest(*records_sha) || !IsLowerHexDigest(*state_sha) ||
      !actual_records_sha || *actual_records_sha != *records_sha) {
    return std::nullopt;
  }
  *source_device = *device;
  *records_sha256 = *records_sha;
  *state_sha256 = *state_sha;
  return root.Clone();
}

std::optional<PasswordSnapshot> ParsePasswordSnapshot(
    const base::FilePath &path) {
  std::string raw;
  if (!PrivateRegularFile(path, kMaxSnapshotBytes, &raw)) {
    return std::nullopt;
  }
  PasswordSnapshot snapshot;
  snapshot.file_sha256 = Sha256(raw);
  std::optional<base::DictValue> root = ParseEnvelope(
      raw, kPasswordKind, kPasswordFormat, &snapshot.source_device,
      &snapshot.records_sha256, &snapshot.state_sha256);
  if (!root) {
    return std::nullopt;
  }
  const base::ListValue *records = root->FindList("records");
  std::set<std::string> keys;
  for (const base::Value &entry : *records) {
    if (!entry.is_dict() ||
        !HasExactKeys(entry.GetDict(), {"key", "payload"})) {
      return std::nullopt;
    }
    const std::string *key = entry.GetDict().FindString("key");
    const base::DictValue *payload = entry.GetDict().FindDict("payload");
    std::optional<Credential> credential =
        payload ? PasswordFromPayload(*payload) : std::nullopt;
    if (!key || !credential || PasswordRecordKey(*credential) != *key ||
        !keys.insert(*key).second) {
      return std::nullopt;
    }
    snapshot.credentials.push_back(std::move(*credential));
  }
  std::optional<std::string> state =
      PasswordStateSha256(snapshot.credentials);
  if (!state || *state != snapshot.state_sha256) {
    return std::nullopt;
  }
  snapshot.record_count = snapshot.credentials.size();
  return snapshot;
}

std::optional<CookieSnapshot> ParseCookieSnapshot(const base::FilePath &path,
                                                  std::string *source_device,
                                                  std::string *file_sha256) {
  std::string raw;
  if (!PrivateRegularFile(path, kMaxSnapshotBytes, &raw)) {
    return std::nullopt;
  }
  *file_sha256 = Sha256(raw);
  std::string records_sha;
  std::string state_sha;
  std::optional<base::DictValue> root =
      ParseEnvelope(raw, kCookieKind, kCookieFormat, source_device,
                    &records_sha, &state_sha);
  if (!root) {
    return std::nullopt;
  }
  std::vector<net::CanonicalCookie> cookies;
  std::set<std::string> keys;
  for (const base::Value &entry : *root->FindList("records")) {
    if (!entry.is_dict() ||
        !HasExactKeys(entry.GetDict(), {"key", "cookie"})) {
      return std::nullopt;
    }
    const std::string *key = entry.GetDict().FindString("key");
    const base::DictValue *value = entry.GetDict().FindDict("cookie");
    std::optional<net::CanonicalCookie> cookie =
        value ? CookieFromValue(*value) : std::nullopt;
    std::optional<std::string> actual_key =
        cookie ? CookieRecordKey(*cookie) : std::nullopt;
    if (!key || !actual_key || *key != *actual_key ||
        !keys.insert(*key).second) {
      return std::nullopt;
    }
    cookies.push_back(std::move(*cookie));
  }
  std::optional<CookieSnapshot> snapshot =
      BuildCookieSnapshot(std::move(cookies), base::Time::Min());
  if (!snapshot || snapshot->records_sha256 != records_sha ||
      snapshot->state_sha256 != state_sha) {
    return std::nullopt;
  }
  return snapshot;
}

RestoreKind RequestedRestoreKind(base::FilePath *source) {
  const base::CommandLine *command = base::CommandLine::ForCurrentProcess();
  const bool passwords = command->HasSwitch(kPasswordRestoreSwitch);
  const bool cookies = command->HasSwitch(kCookieRestoreSwitch);
  if (!passwords && !cookies) {
    return RestoreKind::kNone;
  }
  if (passwords == cookies || command->HasSwitch(kTabRestoreSwitch)) {
    return RestoreKind::kInvalid;
  }
  *source = command->GetSwitchValuePath(passwords ? kPasswordRestoreSwitch
                                                   : kCookieRestoreSwitch);
  return passwords ? RestoreKind::kPasswords : RestoreKind::kCookies;
}

} // namespace

class HeliumNativeRecoveryBridge::Impl
    : public password_manager::PasswordStoreInterface::Observer,
      public password_manager::PasswordStoreConsumer {
public:
  Impl(Profile *profile,
       scoped_refptr<password_manager::PasswordStoreInterface> password_store,
       base::FilePath export_root, std::string device_id)
      : profile_(profile), password_store_(std::move(password_store)),
        export_root_(std::move(export_root)), device_id_(std::move(device_id)),
        receipt_path_(profile->GetPath().AppendASCII(kReceipt)) {}

  ~Impl() override { Stop(); }

  void Start() {
    if (started_) {
      return;
    }
    started_ = true;
    restore_kind_ = RequestedRestoreKind(&restore_source_);
    if (restore_kind_ != RestoreKind::kNone) {
      StartRestore();
      return;
    }
    if (!ValidateExportRoot()) {
      Fail("native recovery export root is invalid");
      return;
    }
    password_store_->AddObserver(this);
    observing_ = true;
    capture_timer_.Start(FROM_HERE, kCaptureInterval,
                         base::BindRepeating(&Impl::CaptureAll,
                                             weak_factory_.GetWeakPtr()));
    CaptureAll();
  }

  void Stop() {
    capture_timer_.Stop();
    if (observing_ && password_store_) {
      password_store_->RemoveObserver(this);
    }
    observing_ = false;
    weak_factory_.InvalidateWeakPtrs();
  }

private:
  void OnLoginsChanged(
      password_manager::PasswordStoreInterface *store,
      const password_manager::PasswordStoreChangeList &) override {
    if (store == password_store_.get()) {
      CaptureAll();
    }
  }

  void OnLoginsRetained(
      password_manager::PasswordStoreInterface *store,
      const std::vector<password_manager::StoredCredential>
          &retained_passwords) override {
    if (store == password_store_.get() &&
        restore_kind_ == RestoreKind::kNone) {
      SavePasswordSnapshot(retained_passwords);
      CaptureCookies();
    }
  }

  void OnGetPasswordStoreResultsOrErrorFrom(
      password_manager::PasswordStoreInterface *store,
      password_manager::LoginsResultOrError results_or_error) override {
    if (store != password_store_.get()) {
      return;
    }
    PasswordRead read = password_read_;
    password_read_ = PasswordRead::kNone;
    auto *credentials =
        std::get_if<password_manager::LoginsResult>(&results_or_error);
    if (!credentials) {
      Fail("native recovery PasswordStore read failed");
      return;
    }
    if (read == PasswordRead::kCapture) {
      SavePasswordSnapshot(*credentials);
      return;
    }
    if (read == PasswordRead::kRestoreInitial) {
      if (!credentials->empty()) {
        Fail("native password restore requires an empty disposable store");
        return;
      }
      expected_passwords_ = ParsePasswordSnapshot(restore_source_);
      if (!expected_passwords_) {
        Fail("native password recovery snapshot is invalid");
        return;
      }
      password_store_->AddLogins(
          std::move(expected_passwords_->credentials),
          base::BindOnce(&Impl::VerifyPasswordRestore,
                         weak_factory_.GetWeakPtr()));
      return;
    }
    if (read == PasswordRead::kRestoreVerify) {
      std::optional<std::string> state = PasswordStateSha256(*credentials);
      if (!expected_passwords_ || !state ||
          *state != expected_passwords_->state_sha256 ||
          credentials->size() != expected_passwords_->record_count) {
        Fail("native password recovery readback mismatch");
        return;
      }
      WriteReceipt(kPasswordKind, expected_passwords_->file_sha256,
                   expected_passwords_->records_sha256,
                   expected_passwords_->state_sha256, credentials->size(),
                   "PasswordStoreInterface");
    }
  }

  void CaptureAll() {
    CapturePasswords();
    CaptureCookies();
  }

  void CapturePasswords() {
    if (password_read_ != PasswordRead::kNone || terminal_) {
      return;
    }
    password_read_ = PasswordRead::kCapture;
    password_store_->GetAllLogins(weak_factory_.GetWeakPtr());
  }

  void CaptureCookies() {
    if (cookie_read_in_flight_ || terminal_) {
      return;
    }
    cookie_read_in_flight_ = true;
    manager()->GetAllCookies(base::BindOnce(&Impl::OnCapturedCookies,
                                            weak_factory_.GetWeakPtr()));
  }

  void OnCapturedCookies(
      const std::vector<net::CanonicalCookie> &cookies) {
    cookie_read_in_flight_ = false;
    std::optional<CookieSnapshot> snapshot =
        BuildCookieSnapshot(cookies);
    if (!snapshot) {
      Fail("native recovery CookieManager snapshot is invalid");
      return;
    }
    std::optional<std::string> raw = MakeSnapshotEnvelope(
        kCookieKind, kCookieFormat, device_id_, snapshot->records,
        snapshot->records_sha256, snapshot->state_sha256);
    if (!raw || !ValidateExportRoot() ||
        !WriteSecretFile(export_root_.AppendASCII(kCookieSnapshot), *raw)) {
      Fail("native recovery cookie snapshot write failed");
    }
  }

  void SavePasswordSnapshot(
      const password_manager::LoginsResult &credentials) {
    if (terminal_) {
      return;
    }
    std::optional<base::ListValue> records = PasswordRecords(credentials);
    std::optional<std::string> records_sha =
        records ? ValueSha256(base::Value(records->Clone())) : std::nullopt;
    std::optional<std::string> state_sha =
        PasswordStateSha256(credentials);
    std::optional<std::string> raw =
        records && records_sha && state_sha
            ? MakeSnapshotEnvelope(kPasswordKind, kPasswordFormat, device_id_,
                                   *records, *records_sha, *state_sha)
            : std::nullopt;
    if (!raw || !ValidateExportRoot() ||
        !WriteSecretFile(export_root_.AppendASCII(kPasswordSnapshot), *raw)) {
      Fail("native recovery password snapshot write failed");
    }
  }

  bool ValidateExportRoot() const {
    if (!password_store_ || !IsValidDevice(device_id_) ||
        !PrivateDirectory(export_root_) ||
        !HasExactPrivateMarker(export_root_, kRootMarker,
                               kRootMarkerContents) ||
        profile_->GetPath().IsParent(export_root_) ||
        export_root_.IsParent(profile_->GetPath())) {
      return false;
    }
    return true;
  }

  bool ValidateRestoreProfile() const {
    if (!password_store_ || restore_kind_ == RestoreKind::kInvalid ||
        restore_source_.empty() || !restore_source_.IsAbsolute() ||
        base::MakeAbsoluteFilePath(restore_source_) != restore_source_ ||
        !PrivateDirectory(profile_->GetPath()) ||
        !HasExactPrivateMarker(profile_->GetPath(), kProfileMarker,
                               kProfileMarkerContents) ||
        base::PathExists(receipt_path_.DirName()) ||
        base::PathExists(receipt_path_) || base::IsLink(receipt_path_) ||
        profile_->GetPath().IsParent(restore_source_)) {
      return false;
    }
#if BUILDFLAG(IS_ANDROID)
    if (profile_->GetPath().BaseName().AsUTF8Unsafe() != "Default" ||
        base::android::apk_info::package_name() !=
            "computer.helium.passwords.test" ||
        !base::android::apk_info::is_debug_app()) {
      return false;
    }
#endif
    return true;
  }

  void StartRestore() {
    if (!ValidateRestoreProfile()) {
      Fail("native recovery disposable boundary is invalid");
      return;
    }
    if (restore_kind_ == RestoreKind::kPasswords) {
      password_read_ = PasswordRead::kRestoreInitial;
      password_store_->GetAllLogins(weak_factory_.GetWeakPtr());
      return;
    }
    if (restore_kind_ == RestoreKind::kCookies) {
      manager()->GetAllCookies(base::BindOnce(&Impl::OnInitialRestoreCookies,
                                              weak_factory_.GetWeakPtr()));
      return;
    }
    Fail("native recovery restore kind is invalid");
  }

  void VerifyPasswordRestore() {
    password_read_ = PasswordRead::kRestoreVerify;
    password_store_->GetAllLogins(weak_factory_.GetWeakPtr());
  }

  void OnInitialRestoreCookies(
      const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> empty =
        BuildCookieSnapshot(cookies);
    if (!empty || !empty->cookies.empty()) {
      Fail("native cookie restore requires an empty disposable store");
      return;
    }
    expected_cookies_ = ParseCookieSnapshot(
        restore_source_, &restore_source_device_, &restore_file_sha256_);
    if (!expected_cookies_) {
      Fail("native cookie recovery snapshot is invalid");
      return;
    }
    for (const auto &[key, cookie] : expected_cookies_->cookies) {
      restore_cookie_queue_.push_back(cookie);
    }
    RestoreNextCookie();
  }

  void RestoreNextCookie() {
    if (restore_cookie_queue_.empty()) {
      manager()->GetAllCookies(base::BindOnce(&Impl::OnRestoredCookies,
                                              weak_factory_.GetWeakPtr()));
      return;
    }
    net::CanonicalCookie cookie = std::move(restore_cookie_queue_.front());
    restore_cookie_queue_.pop_front();
    GURL source = SourceUrlForCookie(cookie);
    if (!source.is_valid()) {
      Fail("native cookie recovery source URL is invalid");
      return;
    }
    manager()->SetCanonicalCookie(
        cookie, source, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(&Impl::OnRestoredCookie, weak_factory_.GetWeakPtr()));
  }

  void OnRestoredCookie(net::CookieAccessResult result) {
    if (!result.status.IsInclude()) {
      Fail("native cookie recovery write was rejected");
      return;
    }
    RestoreNextCookie();
  }

  void OnRestoredCookies(
      const std::vector<net::CanonicalCookie> &cookies) {
    std::optional<CookieSnapshot> restored =
        BuildCookieSnapshot(cookies);
    if (!restored || !expected_cookies_ ||
        restored->records_sha256 != expected_cookies_->records_sha256 ||
        restored->state_sha256 != expected_cookies_->state_sha256 ||
        restored->cookies.size() != expected_cookies_->cookies.size()) {
      Fail("native cookie recovery readback mismatch");
      return;
    }
    WriteReceipt(kCookieKind, restore_file_sha256_,
                 expected_cookies_->records_sha256,
                 expected_cookies_->state_sha256,
                 expected_cookies_->cookies.size(),
                 "network::mojom::CookieManager");
  }

  void WriteReceipt(std::string_view kind, std::string_view snapshot_sha,
                    std::string_view records_sha, std::string_view state_sha,
                    size_t count, std::string_view api) {
    std::string current_source;
    if (terminal_ || !IsLowerHexDigest(snapshot_sha) ||
        !IsLowerHexDigest(records_sha) || !IsLowerHexDigest(state_sha) ||
        !PrivateRegularFile(restore_source_, kMaxSnapshotBytes,
                            &current_source) ||
        Sha256(current_source) != snapshot_sha ||
        !ValidateRestoreProfile() ||
        !base::CreateDirectory(receipt_path_.DirName())) {
      Fail("native recovery receipt boundary is invalid");
      return;
    }
#if BUILDFLAG(IS_POSIX)
    if (!base::SetPosixFilePermissions(receipt_path_.DirName(), 0700)) {
      Fail("native recovery receipt directory is not private");
      return;
    }
#endif
    base::DictValue receipt;
    receipt.Set("schema_version", kReceiptSchema);
    receipt.Set("result", "passed");
    receipt.Set("kind", kind);
    receipt.Set("snapshot_sha256", snapshot_sha);
    receipt.Set("records_sha256", records_sha);
    receipt.Set("restored_state_sha256", state_sha);
    receipt.Set("restored_count", base::checked_cast<int>(count));
    receipt.Set("browser_api", api);
    receipt.Set("completed_at_windows_us", CaptureTime());
    std::string raw;
    if (!base::JSONWriter::Write(receipt, &raw) ||
        !WriteSecretFile(receipt_path_, raw)) {
      Fail("native recovery receipt write failed");
      return;
    }
    terminal_ = true;
    LOG(WARNING) << "Helium native " << kind << " recovery passed";
  }

  void Fail(std::string_view reason) {
    if (terminal_) {
      return;
    }
    terminal_ = true;
    capture_timer_.Stop();
    LOG(ERROR) << "Helium native recovery stopped: " << reason;
  }

  network::mojom::CookieManager *manager() const {
    return profile_->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess();
  }

  raw_ptr<Profile> profile_;
  scoped_refptr<password_manager::PasswordStoreInterface> password_store_;
  base::FilePath export_root_;
  std::string device_id_;
  base::FilePath receipt_path_;
  base::FilePath restore_source_;
  RestoreKind restore_kind_ = RestoreKind::kNone;
  PasswordRead password_read_ = PasswordRead::kNone;
  bool started_ = false;
  bool observing_ = false;
  bool cookie_read_in_flight_ = false;
  bool terminal_ = false;
  std::optional<PasswordSnapshot> expected_passwords_;
  std::optional<CookieSnapshot> expected_cookies_;
  std::string restore_source_device_;
  std::string restore_file_sha256_;
  std::deque<net::CanonicalCookie> restore_cookie_queue_;
  base::RepeatingTimer capture_timer_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

HeliumNativeRecoveryBridge::HeliumNativeRecoveryBridge(
    Profile *profile,
    scoped_refptr<password_manager::PasswordStoreInterface> password_store,
    base::FilePath export_root, std::string device_id)
    : impl_(std::make_unique<Impl>(profile, std::move(password_store),
                                  std::move(export_root),
                                  std::move(device_id))) {}

HeliumNativeRecoveryBridge::~HeliumNativeRecoveryBridge() = default;

bool HeliumNativeRecoveryBridge::IsRestoreRequested() {
  base::FilePath ignored;
  return RequestedRestoreKind(&ignored) != RestoreKind::kNone;
}

void HeliumNativeRecoveryBridge::Start() { impl_->Start(); }

void HeliumNativeRecoveryBridge::Stop() { impl_->Stop(); }

} // namespace helium_sync
