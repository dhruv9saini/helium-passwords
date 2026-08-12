// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"

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
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
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

constexpr size_t kMaxCookieRecords = 50000;
constexpr char kAcceptanceMarker[] = ".helium-cookie-disposable-profile-v1";
#if BUILDFLAG(IS_ANDROID)
constexpr char kAcceptanceMarkerContents[] =
    "helium-cookie-disposable-profile-v1\n";
#endif
constexpr char kAcceptanceReport[] =
    "helium-sync/cookie-native-acceptance.json";
constexpr char kAcceptanceRollback[] =
    "helium-sync/cookie-native-acceptance-rollback.json";

struct CookieSnapshot {
  std::map<std::string, net::CanonicalCookie> cookies;
  std::map<std::string, std::string> cookie_fingerprints;
  base::ListValue serialized;
  std::string fingerprint;
};


struct CookieOperation {
  bool set = false;
  std::string record_key;
  net::CanonicalCookie cookie;
  GURL source_url;
};

std::string Sha256(std::string_view value) {
  return base::HexEncodeLower(crypto::SHA256HashString(value));
}

std::string TimeToJSON(base::Time value) {
  return base::NumberToString(
      value.is_null() ? 0 : value.ToDeltaSinceWindowsEpoch().InMicroseconds());
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
            "computer.helium.passwords.test" ||
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

} // namespace helium_sync
