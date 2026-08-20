// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_

#include <memory>

class Profile;

namespace helium_sync {

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

} // namespace helium_sync

#endif // CHROME_BROWSER_HELIUM_SYNC_HELIUM_COOKIE_SYNC_BRIDGE_H_
