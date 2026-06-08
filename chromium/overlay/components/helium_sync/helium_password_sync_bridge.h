// Copyright 2026 The Helium Authors

#ifndef COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_
#define COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_

#include <memory>
#include <set>
#include <string>
#include <vector>

#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "components/helium_sync/helium_sync_client.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"

namespace helium_sync {

class HeliumPasswordSyncBridge
    : public password_manager::PasswordStoreInterface::Observer,
      public password_manager::PasswordStoreConsumer {
 public:
  HeliumPasswordSyncBridge(
      scoped_refptr<password_manager::PasswordStoreInterface> profile_store,
      std::unique_ptr<HeliumSyncClient> client,
      std::string device_name);
  HeliumPasswordSyncBridge(const HeliumPasswordSyncBridge&) = delete;
  HeliumPasswordSyncBridge& operator=(const HeliumPasswordSyncBridge&) = delete;
  ~HeliumPasswordSyncBridge() override;

  void Start();
  void Stop();
  void PullAndApply();

 private:
  void RequestInitialExport();
  void RequestPostApplyExport();

  struct RemotePasswordRecord {
    std::string key;
    std::string origin_device;
    std::string payload_json;
  };

  enum class PendingRead {
    kNone,
    kInitialExport,
    kApplyRemote,
    kPostApplyExport,
  };

  // PasswordStoreInterface::Observer:
  void OnLoginsChanged(
      password_manager::PasswordStoreInterface* store,
      const password_manager::PasswordStoreChangeList& changes) override;
  void OnLoginsRetained(
      password_manager::PasswordStoreInterface* store,
      const std::vector<password_manager::PasswordForm>& retained_passwords)
      override;

  // PasswordStoreConsumer:
  void OnGetPasswordStoreResultsOrErrorFrom(
      password_manager::PasswordStoreInterface* store,
      password_manager::LoginsResultOrError results_or_error) override;

  void ExportInitialPasswords(
      const password_manager::LoginsResult& credentials);
  void ApplyRemotePasswords(
      const password_manager::LoginsResult& local_credentials);
  void PushRecords(std::vector<Record> records);
  void OnPushComplete(bool ok, std::string error);
  void OnPullComplete(bool ok, std::string response_json, std::string error);
  void AddRemoteLoginAfterUpdate(
      password_manager::LoginsResult::value_type credential);
  void OnRemoteWriteAndExportComplete();
  void OnRemoteWriteComplete();
  std::set<std::string> KeysFor(
      const password_manager::LoginsResult& credentials) const;

  scoped_refptr<password_manager::PasswordStoreInterface> profile_store_;
  std::unique_ptr<HeliumSyncClient> client_;
  std::string device_name_;
  bool observing_ = false;
  bool pull_in_flight_ = false;
  int suppress_local_changes_ = 0;
  PendingRead pending_read_ = PendingRead::kNone;
  std::set<std::string> known_keys_;
  std::vector<RemotePasswordRecord> pending_remote_records_;
  int initial_empty_read_retries_ = 0;
  int post_apply_empty_read_retries_ = 0;
  base::RepeatingTimer pull_timer_;
  base::WeakPtrFactory<HeliumPasswordSyncBridge> weak_factory_{this};
};

}  // namespace helium_sync

#endif  // COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_
