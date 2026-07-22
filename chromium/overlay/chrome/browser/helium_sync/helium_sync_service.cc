// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_sync_service.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/base64.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/helium_sync/helium_cookie_sync_bridge.h"
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

#if __has_include( \
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

#if BUILDFLAG(IS_ANDROID)
void AndroidStatusLog(const std::string& message) {
  __android_log_write(ANDROID_LOG_WARN, "HeliumSync", message.c_str());
}
#else
void AndroidStatusLog(const std::string&) {}
#endif

std::optional<std::string> ReadConfigValue(const base::FilePath& config_dir,
                                           const char* leaf) {
  std::string value;
  if (!base::ReadFileToString(config_dir.AppendASCII(leaf), &value)) {
    return std::nullopt;
  }
  value = std::string(base::TrimWhitespaceASCII(value, base::TRIM_ALL));
  return value.empty() ? std::nullopt
                       : std::optional<std::string>(std::move(value));
}

std::optional<std::string> ReadClientDeviceId(
    const base::FilePath& client_state_path) {
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
  const base::DictValue& state = parsed->GetDict();
  const std::string* device_id = state.FindString("device_id");
  const std::string* role = state.FindString("role");
  const std::string* phase = state.FindString("phase");
  const std::string* active_key_id = state.FindString("active_key_id");
  const base::DictValue* keys = state.FindDict("keys");
  if (!device_id || device_id->empty() || !role ||
      (*role != "seed" && *role != "join") || !phase ||
      (*phase != "pending" && *phase != "active") ||
      !active_key_id || active_key_id->empty() || !keys || keys->empty() ||
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
  return *device_id;
}

}  // namespace

HeliumSyncService::HeliumSyncService(Profile* profile) {
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
  std::optional<std::string> device_id = ReadClientDeviceId(client_state_path);
  GURL base_url(base_url_value.value_or(""));
  if (!token || !device_id || !base_url.is_valid() ||
      !base_url.SchemeIs(url::kHttpsScheme) || base_url.host().empty() ||
      base_url.has_username() || base_url.has_password()) {
    LOG(WARNING) << "Helium sync inactive: profile-local enrollment config is "
                    "missing or invalid";
    AndroidStatusLog("inactive: profile-local enrollment config invalid");
    return;
  }

  LOG(WARNING) << "Helium sync starting from profile-local enrollment";
  AndroidStatusLog("starting from profile-local enrollment");
  auto cookie_client = std::make_unique<helium_sync::HeliumSyncClient>(
      profile->GetURLLoaderFactory(), base_url, *token, client_state_path);
  cookie_bridge_ = std::make_unique<helium_sync::HeliumCookieSyncBridge>(
      profile, std::move(cookie_client),
      config_dir.AppendASCII(kCookieStateFile),
      config_dir.AppendASCII(kCookieRollbackFile),
      config_dir.AppendASCII(kCookieReauthSignalFile));
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
      password_store, std::move(client), *device_id,
      config_dir.AppendASCII(kPasswordStateFile));
  password_bridge_->Start();
}

HeliumSyncService::~HeliumSyncService() = default;

void HeliumSyncService::Shutdown() {
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
}
