// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_

#include <cstdint>
#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"

class Profile;

namespace helium_sync {

class HeliumSyncClient;

// Runs a fixed, synthetic CookieManager transaction only in a newly marked
// computer.helium.sync.test profile. It never participates in normal sync and
// emits content-free acceptance evidence at a fixed profile-local path.
class HeliumCookieAcceptanceFixture {
public:
  explicit HeliumCookieAcceptanceFixture(Profile *profile);
  HeliumCookieAcceptanceFixture(const HeliumCookieAcceptanceFixture &) = delete;
  HeliumCookieAcceptanceFixture &
  operator=(const HeliumCookieAcceptanceFixture &) = delete;
  ~HeliumCookieAcceptanceFixture();

  static bool IsRequested(Profile *profile);

  void Start();
  void Stop();

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

// Reconciles the complete live cookie profile through Chromium's privileged
// CookieManager. The bridge never opens or merges Chromium's cookie database.
class HeliumCookieSyncBridge {
public:
  HeliumCookieSyncBridge(
      Profile *profile, std::unique_ptr<HeliumSyncClient> client,
      base::FilePath state_path, base::FilePath rollback_path,
      base::FilePath reauth_signal_path,
      base::RepeatingCallback<void(int64_t)> verified_baseline_callback);
  HeliumCookieSyncBridge(const HeliumCookieSyncBridge &) = delete;
  HeliumCookieSyncBridge &operator=(const HeliumCookieSyncBridge &) = delete;
  ~HeliumCookieSyncBridge();

  void Start();
  void Stop();
  void PullAndApply();
  bool EnrollmentActivated(std::string *error);

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace helium_sync

#endif // CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
