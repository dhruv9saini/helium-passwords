// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_

#include <memory>
#include <string>

#include "base/files/file_path.h"

class Profile;

namespace helium_sync {

class HeliumSyncClient;

// Reconciles configured cookie domains through Chromium's privileged
// CookieManager. A policy has exactly one source; replicas never publish.
class HeliumCookieSyncBridge {
 public:
  HeliumCookieSyncBridge(Profile* profile,
                         std::unique_ptr<HeliumSyncClient> client,
                         std::string device_name,
                         base::FilePath policies_path,
                         base::FilePath state_path);
  HeliumCookieSyncBridge(const HeliumCookieSyncBridge&) = delete;
  HeliumCookieSyncBridge& operator=(const HeliumCookieSyncBridge&) = delete;
  ~HeliumCookieSyncBridge();

  void Start();
  void Stop();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace helium_sync

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
