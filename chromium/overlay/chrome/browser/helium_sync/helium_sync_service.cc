// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_sync_service.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/base64.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"
#include "chrome/browser/helium_sync/helium_tab_journal_bridge.h"
#include "chrome/browser/helium_sync/helium_tab_restore_bridge.h"
#include "chrome/browser/helium_sync/helium_tab_snapshot_bridge.h"
#include "chrome/browser/profiles/profile.h"
#include "components/helium_sync/helium_password_sync_bridge.h"
#include "components/helium_sync/helium_sync_client.h"
#include "components/keyed_service/core/service_access_type.h"
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
constexpr char kCookieStateFile[] = "cookie-state.json";
constexpr char kCookieRollbackFile[] = "cookie-rollback.json";
constexpr char kCookieReauthSignalFile[] = "cookie-reauth-required.json";
constexpr char kTabSnapshotExportPathFile[] = "tab_snapshot_export_path";
constexpr char kTabJournalRootFile[] = "tab_journal_root";

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
      parsed->GetDict().FindInt("version").value_or(0) != 1) {
    return std::nullopt;
  }
  const base::DictValue &state = parsed->GetDict();
  const std::string *device_id = state.FindString("device_id");
  const std::string *role = state.FindString("role");
  const std::string *phase = state.FindString("phase");
  const std::string *active_key_id = state.FindString("active_key_id");
  const base::DictValue *keys = state.FindDict("keys");
  if (!device_id || device_id->empty() || !role ||
      (*role != "seed" && *role != "join") || !phase ||
      (*phase != "pending" && *phase != "active") || !active_key_id ||
      active_key_id->empty() || !keys || keys->empty() ||
      !keys->Find(*active_key_id) || (*role == "seed" && *device_id != "d") ||
      (*role == "join" && *device_id == "d")) {
    return std::nullopt;
  }
  for (const auto [key_id, encoded] : *keys) {
    if (key_id.empty() || !encoded.is_string()) {
      return std::nullopt;
    }
    std::optional<std::vector<uint8_t>> decoded =
        base::Base64Decode(encoded.GetString());
    if (!decoded || decoded->size() != 32) {
      return std::nullopt;
    }
  }
  return ClientEnrollment{*device_id, *phase};
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
  if (std::optional<std::string> journal_root =
          ReadConfigValue(config_dir, kTabJournalRootFile)) {
    tab_journal_bridge_ = std::make_unique<helium_sync::HeliumTabJournalBridge>(
        profile, base::FilePath::FromUTF8Unsafe(*journal_root));
    tab_journal_bridge_->Start();
  }

  std::optional<std::string> token = ReadConfigValue(config_dir, kTokenFile);
  std::optional<std::string> base_url_value =
      ReadConfigValue(config_dir, kBaseUrlFile);
  const base::FilePath client_state_path =
      config_dir.AppendASCII(kClientStateFile);
  std::optional<ClientEnrollment> enrollment =
      ReadClientEnrollment(client_state_path);
  GURL base_url(base_url_value.value_or(""));
  if (!token || !enrollment || !base_url.is_valid() ||
      !base_url.SchemeIs(url::kHttpsScheme) || base_url.host().empty() ||
      base_url.has_username() || base_url.has_password()) {
    LOG(WARNING) << "Helium sync inactive: profile-local enrollment config is "
                    "missing or invalid";
    AndroidStatusLog("inactive: profile-local enrollment config invalid");
    return;
  }

  LOG(WARNING) << "Helium sync starting from profile-local enrollment";
  AndroidStatusLog("starting from profile-local enrollment");
  base::RepeatingCallback<void(int64_t)> cookie_baseline_callback;
  base::RepeatingCallback<void(int64_t)> password_baseline_callback;
  if (enrollment->phase == "pending") {
    enrollment_client_ = std::make_unique<helium_sync::HeliumSyncClient>(
        profile->GetURLLoaderFactory(), base_url, *token, client_state_path);
    cookie_baseline_callback =
        base::BindRepeating(&HeliumSyncService::OnCookieBaselineVerified,
                            weak_factory_.GetWeakPtr());
    password_baseline_callback =
        base::BindRepeating(&HeliumSyncService::OnPasswordBaselineVerified,
                            weak_factory_.GetWeakPtr());
  }
  auto cookie_client = std::make_unique<helium_sync::HeliumSyncClient>(
      profile->GetURLLoaderFactory(), base_url, *token, client_state_path);
  cookie_bridge_ = std::make_unique<helium_sync::HeliumCookieSyncBridge>(
      profile, std::move(cookie_client),
      config_dir.AppendASCII(kCookieStateFile),
      config_dir.AppendASCII(kCookieRollbackFile),
      config_dir.AppendASCII(kCookieReauthSignalFile),
      std::move(cookie_baseline_callback));
  cookie_bridge_->Start();

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
}

HeliumSyncService::~HeliumSyncService() = default;

void HeliumSyncService::Shutdown() {
  weak_factory_.InvalidateWeakPtrs();
  if (cookie_acceptance_fixture_) {
    cookie_acceptance_fixture_->Stop();
    cookie_acceptance_fixture_.reset();
  }
  if (cookie_bridge_) {
    cookie_bridge_->Stop();
    cookie_bridge_.reset();
  }
  if (password_bridge_) {
    password_bridge_->Stop();
    password_bridge_.reset();
  }
  if (tab_snapshot_bridge_) {
    tab_snapshot_bridge_->Stop();
    tab_snapshot_bridge_.reset();
  }
  if (tab_journal_bridge_) {
    tab_journal_bridge_->Stop();
    tab_journal_bridge_.reset();
  }
  if (tab_restore_bridge_) {
    tab_restore_bridge_->Stop();
    tab_restore_bridge_.reset();
  }
  enrollment_client_.reset();
}

void HeliumSyncService::OnCookieBaselineVerified(int64_t sequence) {
  if (enrollment_complete_) {
    return;
  }
  cookie_verified_sequence_ = sequence;
  MaybeCompleteEnrollment();
}

void HeliumSyncService::OnPasswordBaselineVerified(int64_t sequence) {
  if (enrollment_complete_) {
    return;
  }
  password_verified_sequence_ = sequence;
  MaybeCompleteEnrollment();
}

void HeliumSyncService::MaybeCompleteEnrollment() {
  if (!enrollment_client_ || !cookie_bridge_ || !password_bridge_ ||
      enrollment_completion_in_flight_ || !cookie_verified_sequence_ ||
      !password_verified_sequence_) {
    return;
  }
  if (*cookie_verified_sequence_ != *password_verified_sequence_) {
    cookie_verified_sequence_.reset();
    password_verified_sequence_.reset();
    cookie_bridge_->PullAndApply();
    password_bridge_->PullAndApply();
    return;
  }

  const int64_t verified_sequence = *cookie_verified_sequence_;
  std::string error;
  if (!enrollment_client_->AcknowledgeApplied(verified_sequence, &error)) {
    LOG(WARNING) << "Helium enrollment coordinator could not acknowledge the "
                    "joint verified cursor: "
                 << error;
    AndroidStatusLog("enrollment joint cursor acknowledgement failed");
    cookie_verified_sequence_.reset();
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
    cookie_verified_sequence_.reset();
    password_verified_sequence_.reset();
    return;
  }

  std::string cookie_error;
  std::string password_error;
  const bool cookie_active = cookie_bridge_->EnrollmentActivated(&cookie_error);
  const bool password_active =
      password_bridge_->EnrollmentActivated(&password_error);
  if (!cookie_active || !password_active) {
    LOG(WARNING) << "Helium enrollment activated but bridge state reload "
                    "failed closed: cookie="
                 << cookie_error << " password=" << password_error;
    AndroidStatusLog("enrollment bridge state reload failed closed");
    return;
  }

  enrollment_complete_ = true;
  LOG(WARNING) << "Helium password and cookie enrollment activated at joint "
                  "verified cursor "
               << *cookie_verified_sequence_;
  AndroidStatusLog("password and cookie enrollment activated");
  cookie_bridge_->PullAndApply();
  password_bridge_->PullAndApply();
}
