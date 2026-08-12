// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_sync_service.h"

#include <cstdint>
#include <optional>
#include <string>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"
#include "chrome/browser/helium_sync/helium_native_recovery_bridge.h"
#include "chrome/browser/helium_sync/helium_tab_restore_bridge.h"
#include "chrome/browser/helium_sync/helium_tab_snapshot_bridge.h"
#include "chrome/browser/profiles/profile.h"
#include "components/helium_sync/helium_password_sync_bridge.h"
#include "components/helium_sync/helium_sync_client.h"
#include "components/keyed_service/core/service_access_type.h"
#include "net/base/ip_address.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "url/gurl.h"
#include "url/url_constants.h"

#if BUILDFLAG(IS_ANDROID)
#include <android/log.h>

#include "base/base_paths_android.h"
#endif

#if __has_include(                                                             \
    "chrome/browser/password_manager/factories/profile_password_store_factory.h")
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#else
#include "chrome/browser/password_manager/profile_password_store_factory.h"
#endif

namespace {

constexpr char kConfigDir[] = "helium-sync";
constexpr char kTokenFile[] = "token";
constexpr char kBaseUrlFile[] = "base_url";
constexpr char kClientStateFile[] = "client.json";
constexpr char kPasswordStateFile[] = "password-state.json";
constexpr char kTabSnapshotExportPathFile[] = "tab_snapshot_export_path";
constexpr char kNativeRecoveryRootFile[] = "native_recovery_root";

#if BUILDFLAG(IS_ANDROID)
void AndroidStatusLog(const std::string &message) {
  __android_log_write(ANDROID_LOG_WARN, "HeliumSync", message.c_str());
}
#else
void AndroidStatusLog(const std::string &) {}
#endif

std::optional<std::string> ReadConfigValue(const base::FilePath &config_dir,
                                           const char *leaf) {
  std::string value;
  if (!base::ReadFileToString(config_dir.AppendASCII(leaf), &value)) {
    return std::nullopt;
  }
  value = std::string(base::TrimWhitespaceASCII(value, base::TRIM_ALL));
  return value.empty() ? std::nullopt
                       : std::optional<std::string>(std::move(value));
}

struct ClientEnrollment {
  std::string device_id;
  std::string phase;
};

std::optional<ClientEnrollment>
ReadClientEnrollment(const base::FilePath &client_state_path) {
  std::string raw;
  if (!base::ReadFileToString(client_state_path, &raw)) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("version").value_or(0) != 2) {
    return std::nullopt;
  }
  const base::DictValue &state = parsed->GetDict();
  const std::string *device_id = state.FindString("device_id");
  const std::string *role = state.FindString("role");
  const std::string *phase = state.FindString("phase");
  const base::DictValue *revisions = state.FindDict("revisions");
  const std::string *sequence = state.FindString("sequence");
  int64_t parsed_sequence = -1;
  if (!device_id || device_id->empty() || !role ||
      (*role != "seed" && *role != "join") || !phase ||
      (*phase != "pending" && *phase != "active") || !revisions || !sequence ||
      !base::StringToInt64(*sequence, &parsed_sequence) ||
      parsed_sequence < 0 || (*role == "seed" && *device_id != "d") ||
      (*role == "join" && *device_id == "d")) {
    return std::nullopt;
  }
  for (const auto [identity, revision] : *revisions) {
    int64_t parsed_revision = -1;
    if (identity.empty() || !revision.is_string() ||
        !base::StringToInt64(revision.GetString(), &parsed_revision) ||
        parsed_revision < 0) {
      return std::nullopt;
    }
  }
  return ClientEnrollment{*device_id, *phase};
}

bool IsPrivateSyncEndpoint(const GURL &endpoint) {
  if (!endpoint.is_valid() || !endpoint.SchemeIs(url::kHttpScheme) ||
      endpoint.host().empty() || endpoint.has_username() ||
      endpoint.has_password() || endpoint.has_query() || endpoint.has_ref() ||
      endpoint.path() != "/") {
    return false;
  }
  net::IPAddress address;
  if (!address.AssignFromIPLiteral(endpoint.host())) {
    return false;
  }
  return address.IsLoopback() ||
         (address.IsIPv4() && net::IPAddressMatchesPrefix(
                                  address, net::IPAddress(100, 64, 0, 0), 10));
}

} // namespace

HeliumSyncService::HeliumSyncService(Profile *profile) {
  if (helium_sync::HeliumCookieAcceptanceFixture::IsRequested(profile)) {
    cookie_acceptance_fixture_ =
        std::make_unique<helium_sync::HeliumCookieAcceptanceFixture>(profile);
    cookie_acceptance_fixture_->Start();
    // A marked cookie fixture profile is a dedicated disposable process. A
    // malformed marker or failed fixture must never fall through to sync.
    return;
  }

  if (helium_sync::HeliumNativeRecoveryBridge::IsRestoreRequested()) {
    scoped_refptr<password_manager::PasswordStoreInterface> password_store =
        ProfilePasswordStoreFactory::GetForProfile(
            profile, ServiceAccessType::EXPLICIT_ACCESS);
    if (!password_store) {
      LOG(ERROR) << "Helium native recovery refused: password store "
                    "unavailable";
      return;
    }
    recovery_bridge_ =
        std::make_unique<helium_sync::HeliumNativeRecoveryBridge>(
            profile, std::move(password_store), base::FilePath(), "");
    recovery_bridge_->Start();
    // Restore switches always select a dedicated disposable process. Invalid
    // requests fail closed and never reach sync or tab export.
    return;
  }

  if (helium_sync::HeliumTabRestoreBridge::IsRequested()) {
    tab_restore_bridge_ =
        std::make_unique<helium_sync::HeliumTabRestoreBridge>(profile);
    tab_restore_bridge_->Start();
    // This command line is a dedicated disposable recovery process. Even a
    // malformed restore request must never fall through into export or network
    // synchronization against the selected profile.
    return;
  }

  const base::FilePath config_dir = profile->GetPath().AppendASCII(kConfigDir);
  if (std::optional<std::string> export_path =
          ReadConfigValue(config_dir, kTabSnapshotExportPathFile)) {
    tab_snapshot_bridge_ =
        std::make_unique<helium_sync::HeliumTabSnapshotBridge>(
            profile, base::FilePath::FromUTF8Unsafe(*export_path));
    tab_snapshot_bridge_->Start();
  }
  std::optional<std::string> token = ReadConfigValue(config_dir, kTokenFile);
  std::optional<std::string> base_url_value =
      ReadConfigValue(config_dir, kBaseUrlFile);
  const base::FilePath client_state_path =
      config_dir.AppendASCII(kClientStateFile);
  std::optional<ClientEnrollment> enrollment =
      ReadClientEnrollment(client_state_path);
  GURL base_url(base_url_value.value_or(""));
  if (!token || !enrollment || !IsPrivateSyncEndpoint(base_url)) {
    LOG(WARNING) << "Helium sync inactive: profile-local enrollment config is "
                    "missing or invalid";
    AndroidStatusLog("inactive: profile-local enrollment config invalid");
    return;
  }

  LOG(WARNING) << "Helium sync starting from profile-local enrollment";
  AndroidStatusLog("starting from profile-local enrollment");
  base::RepeatingCallback<void(int64_t)> password_baseline_callback;
  if (enrollment->phase == "pending") {
    enrollment_client_ = std::make_unique<helium_sync::HeliumSyncClient>(
        profile->GetURLLoaderFactory(), base_url, *token, client_state_path);
    password_baseline_callback =
        base::BindRepeating(&HeliumSyncService::OnPasswordBaselineVerified,
                            weak_factory_.GetWeakPtr());
  }

  scoped_refptr<password_manager::PasswordStoreInterface> password_store =
      ProfilePasswordStoreFactory::GetForProfile(
          profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!password_store) {
    LOG(WARNING) << "Helium password sync inactive: password store unavailable";
    AndroidStatusLog("password sync inactive: password store unavailable");
    return;
  }

  auto client = std::make_unique<helium_sync::HeliumSyncClient>(
      profile->GetURLLoaderFactory(), base_url, *token, client_state_path);
  password_bridge_ = std::make_unique<helium_sync::HeliumPasswordSyncBridge>(
      password_store, std::move(client), enrollment->device_id,
      config_dir.AppendASCII(kPasswordStateFile),
      std::move(password_baseline_callback));
  password_bridge_->Start();

  if (std::optional<std::string> recovery_root =
          ReadConfigValue(config_dir, kNativeRecoveryRootFile)) {
    recovery_bridge_ =
        std::make_unique<helium_sync::HeliumNativeRecoveryBridge>(
            profile, password_store,
            base::FilePath::FromUTF8Unsafe(*recovery_root),
            enrollment->device_id);
    recovery_bridge_->Start();
  } else {
    LOG(WARNING) << "Helium native recovery snapshots inactive: "
                    "profile-local root is missing";
  }
}

HeliumSyncService::~HeliumSyncService() = default;

void HeliumSyncService::Shutdown() {
  weak_factory_.InvalidateWeakPtrs();
  if (recovery_bridge_) {
    recovery_bridge_->Stop();
    recovery_bridge_.reset();
  }
  if (cookie_acceptance_fixture_) {
    cookie_acceptance_fixture_->Stop();
    cookie_acceptance_fixture_.reset();
  }
  if (password_bridge_) {
    password_bridge_->Stop();
    password_bridge_.reset();
  }
  if (tab_snapshot_bridge_) {
    tab_snapshot_bridge_->Stop();
    tab_snapshot_bridge_.reset();
  }
  if (tab_restore_bridge_) {
    tab_restore_bridge_->Stop();
    tab_restore_bridge_.reset();
  }
  enrollment_client_.reset();
}

void HeliumSyncService::OnPasswordBaselineVerified(int64_t sequence) {
  if (enrollment_complete_) {
    return;
  }
  password_verified_sequence_ = sequence;
  MaybeCompleteEnrollment();
}

void HeliumSyncService::MaybeCompleteEnrollment() {
  if (!enrollment_client_ || !password_bridge_ ||
      enrollment_completion_in_flight_ || !password_verified_sequence_) {
    return;
  }

  const int64_t verified_sequence = *password_verified_sequence_;
  std::string error;
  if (!enrollment_client_->AcknowledgeApplied(verified_sequence, &error)) {
    LOG(WARNING) << "Helium enrollment coordinator could not acknowledge the "
                    "joint verified cursor: "
                 << error;
    AndroidStatusLog("enrollment joint cursor acknowledgement failed");
    password_verified_sequence_.reset();
    return;
  }
  enrollment_completion_in_flight_ = true;
  enrollment_client_->CompleteEnrollment(
      verified_sequence,
      base::BindOnce(&HeliumSyncService::OnEnrollmentComplete,
                     weak_factory_.GetWeakPtr()));
}

void HeliumSyncService::OnEnrollmentComplete(bool ok, std::string error) {
  enrollment_completion_in_flight_ = false;
  if (!ok) {
    LOG(WARNING) << "Helium joint enrollment completion failed: " << error;
    AndroidStatusLog("joint enrollment completion failed");
    password_verified_sequence_.reset();
    return;
  }

  std::string password_error;
  const bool password_active =
      password_bridge_->EnrollmentActivated(&password_error);
  if (!password_active) {
    LOG(WARNING) << "Helium enrollment activated but password bridge state "
                    "reload failed closed: "
                 << password_error;
    AndroidStatusLog("enrollment bridge state reload failed closed");
    return;
  }

  enrollment_complete_ = true;
  LOG(WARNING) << "Helium password enrollment activated at verified cursor "
               << *password_verified_sequence_;
  AndroidStatusLog("password enrollment activated");
  password_bridge_->PullAndApply();
}
