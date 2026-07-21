// Copyright 2026 The Helium Authors

#ifndef CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_
#define CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_

#include <memory>

#include "components/keyed_service/core/keyed_service.h"

class Profile;

namespace helium_sync {
class HeliumCookieSyncBridge;
class HeliumPasswordSyncBridge;
class HeliumTabSnapshotBridge;
}  // namespace helium_sync

class HeliumSyncService : public KeyedService {
 public:
  explicit HeliumSyncService(Profile* profile);
  HeliumSyncService(const HeliumSyncService&) = delete;
  HeliumSyncService& operator=(const HeliumSyncService&) = delete;
  ~HeliumSyncService() override;

  // KeyedService:
  void Shutdown() override;

 private:
  std::unique_ptr<helium_sync::HeliumCookieSyncBridge> cookie_bridge_;
  std::unique_ptr<helium_sync::HeliumPasswordSyncBridge> password_bridge_;
  std::unique_ptr<helium_sync::HeliumTabSnapshotBridge> tab_snapshot_bridge_;
};

#endif  // CHROME_BROWSER_HELIUM_SYNC_HELIUM_SYNC_SERVICE_H_
