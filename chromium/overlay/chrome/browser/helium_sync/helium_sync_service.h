// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "components/keyed_service/core/keyed_service.h"

class Profile;

namespace helium_sync {
class HeliumCookieAcceptanceFixture;
class HeliumNativeRecoveryBridge;
class HeliumPasswordSyncBridge;
class HeliumSyncClient;
class HeliumTabRestoreBridge;
class HeliumTabSnapshotBridge;
} // namespace helium_sync

class HeliumSyncService : public KeyedService {
public:
  explicit HeliumSyncService(Profile *profile);
  HeliumSyncService(const HeliumSyncService &) = delete;
  HeliumSyncService &operator=(const HeliumSyncService &) = delete;
  ~HeliumSyncService() override;

  // KeyedService:
  void Shutdown() override;

private:
  void OnPasswordBaselineVerified(int64_t sequence);
  void MaybeCompleteEnrollment();
  void OnEnrollmentComplete(bool ok, std::string error);

  std::unique_ptr<helium_sync::HeliumCookieAcceptanceFixture>
      cookie_acceptance_fixture_;
  std::unique_ptr<helium_sync::HeliumNativeRecoveryBridge> recovery_bridge_;
  std::unique_ptr<helium_sync::HeliumPasswordSyncBridge> password_bridge_;
  std::unique_ptr<helium_sync::HeliumSyncClient> enrollment_client_;
  std::unique_ptr<helium_sync::HeliumTabRestoreBridge> tab_restore_bridge_;
  std::unique_ptr<helium_sync::HeliumTabSnapshotBridge> tab_snapshot_bridge_;
  std::optional<int64_t> password_verified_sequence_;
  bool enrollment_completion_in_flight_ = false;
  bool enrollment_complete_ = false;
  base::WeakPtrFactory<HeliumSyncService> weak_factory_{this};
};

#endif // CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_
