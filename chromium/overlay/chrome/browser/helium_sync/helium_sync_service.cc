// Copyright 2026 The Helium Authors

#include "chrome/browser/helium_sync/helium_sync_service.h"

#include <optional>
#include <string>
#include <vector>

#include "base/base_paths.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/strings/string_util.h"
#include "base/system/sys_info.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_paths.h"
#include "components/helium_sync/helium_password_sync_bridge.h"
#include "components/helium_sync/helium_sync_client.h"
#include "components/keyed_service/core/service_access_type.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "url/gurl.h"

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
constexpr char kDeviceNameFile[] = "device_name";
constexpr char kDefaultBaseUrl[] = "http://127.0.0.1:44719";

#if BUILDFLAG(IS_ANDROID)
void AndroidStatusLog(const std::string& message) {
  __android_log_write(ANDROID_LOG_WARN, "HeliumSync", message.c_str());
}
#else
void AndroidStatusLog(const std::string&) {}
#endif

std::vector<base::FilePath> CandidateConfigPaths(Profile* profile,
                                                 const char* leaf) {
  std::vector<base::FilePath> paths;
  paths.push_back(profile->GetPath().AppendASCII(kConfigDir).AppendASCII(leaf));

  base::FilePath user_data_dir;
  if (base::PathService::Get(chrome::DIR_USER_DATA, &user_data_dir)) {
    paths.push_back(user_data_dir.AppendASCII(kConfigDir).AppendASCII(leaf));
  }

  base::FilePath home_dir;
  if (base::PathService::Get(base::DIR_HOME, &home_dir)) {
    paths.push_back(home_dir.AppendASCII(".local")
                        .AppendASCII("share")
                        .AppendASCII(kConfigDir)
                        .AppendASCII(leaf));
  }

#if BUILDFLAG(IS_ANDROID)
  base::FilePath app_data_dir;
  if (base::PathService::Get(base::DIR_ANDROID_APP_DATA, &app_data_dir)) {
    paths.push_back(app_data_dir.AppendASCII(kConfigDir).AppendASCII(leaf));
  }
#endif

  return paths;
}

std::optional<std::string> ReadFirstConfigValue(Profile* profile,
                                                const char* leaf) {
  for (const base::FilePath& path : CandidateConfigPaths(profile, leaf)) {
    std::string value;
    if (!base::ReadFileToString(path, &value)) {
      continue;
    }
    value = std::string(base::TrimWhitespaceASCII(value, base::TRIM_ALL));
    if (!value.empty()) {
      return value;
    }
  }
  return std::nullopt;
}

GURL ReadBaseUrl(Profile* profile) {
  std::string base_url =
      ReadFirstConfigValue(profile, kBaseUrlFile).value_or(kDefaultBaseUrl);
  GURL url(base_url);
  return url.is_valid() ? url : GURL(kDefaultBaseUrl);
}

std::string ReadDeviceName(Profile* profile) {
  if (std::optional<std::string> device_name =
          ReadFirstConfigValue(profile, kDeviceNameFile)) {
    return *device_name;
  }

  return "helium-" + base::SysInfo::OperatingSystemName() + "-" +
         profile->GetPath().BaseName().AsUTF8Unsafe();
}

}  // namespace

HeliumSyncService::HeliumSyncService(Profile* profile) {
  std::optional<std::string> token = ReadFirstConfigValue(profile, kTokenFile);
  if (!token) {
    LOG(WARNING) << "Helium sync inactive: no token config for profile "
                 << profile->GetPath();
    AndroidStatusLog("inactive: no token config for profile " +
                     profile->GetPath().AsUTF8Unsafe());
    return;
  }

  scoped_refptr<password_manager::PasswordStoreInterface> password_store =
      ProfilePasswordStoreFactory::GetForProfile(
          profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!password_store) {
    LOG(WARNING) << "Helium sync inactive: no password store for profile "
                 << profile->GetPath();
    AndroidStatusLog("inactive: no password store for profile " +
                     profile->GetPath().AsUTF8Unsafe());
    return;
  }

  std::string device_name = ReadDeviceName(profile);
  LOG(WARNING) << "Helium sync starting for device " << device_name
               << " profile " << profile->GetPath();
  AndroidStatusLog("starting for device " + device_name);
  auto client = std::make_unique<helium_sync::HeliumSyncClient>(
      profile->GetURLLoaderFactory(), ReadBaseUrl(profile), *token,
      device_name);
  password_bridge_ = std::make_unique<helium_sync::HeliumPasswordSyncBridge>(
      password_store, std::move(client), std::move(device_name));
  password_bridge_->Start();
}

HeliumSyncService::~HeliumSyncService() = default;

void HeliumSyncService::Shutdown() {
  if (password_bridge_) {
    password_bridge_->Stop();
    password_bridge_.reset();
  }
}
