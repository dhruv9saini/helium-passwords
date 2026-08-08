// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_NATIVE_RECOVERY_BRIDGE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_NATIVE_RECOVERY_BRIDGE_H_

#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/memory/scoped_refptr.h"

class Profile;

namespace password_manager {
class PasswordStoreInterface;
}

namespace helium_sync {

// Produces complete, browser-native, neutral password and cookie snapshots
// without reading either backing database. A dedicated command-line mode can
// restore exactly one snapshot into a newly marked disposable profile through
// PasswordStoreInterface or CookieManager and emits a content-free receipt.
// It is intentionally independent from the Tailnet journal and stopped-profile
// archive recovery mechanisms.
class HeliumNativeRecoveryBridge {
public:
  HeliumNativeRecoveryBridge(
      Profile *profile,
      scoped_refptr<password_manager::PasswordStoreInterface> password_store,
      base::FilePath export_root, std::string device_id);
  HeliumNativeRecoveryBridge(const HeliumNativeRecoveryBridge &) = delete;
  HeliumNativeRecoveryBridge &
  operator=(const HeliumNativeRecoveryBridge &) = delete;
  ~HeliumNativeRecoveryBridge();

  // Presence of either restore switch selects a dedicated, fail-closed
  // disposable recovery process. Malformed values still return true.
  static bool IsRestoreRequested();

  void Start();
  void Stop();

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace helium_sync

#endif // CHROME_BROWSER_HELIUM_SYNC_HELIUM_NATIVE_RECOVERY_BRIDGE_H_
