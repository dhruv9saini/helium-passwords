// Copyright 2026 The Helium Authors

#ifndef COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_
#define COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "base/files/file_path.h"
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
      std::unique_ptr<HeliumSyncClient> client, std::string device_name,
      base::FilePath state_path,
      base::RepeatingCallback<void(int64_t)> verified_baseline_callback);
  HeliumPasswordSyncBridge(const HeliumPasswordSyncBridge &) = delete;
  HeliumPasswordSyncBridge &
  operator=(const HeliumPasswordSyncBridge &) = delete;
  ~HeliumPasswordSyncBridge() override;

  void Start();
  void Stop();
  void PullAndApply();
  bool EnrollmentActivated(std::string *error);

private:
  void RequestReconcileRead();
  void RequestPostApplyRead();

  struct CredentialState {
    std::string fingerprint;
    int64_t remote_seq = 0;
    int64_t revision = 0;
    bool deleted = false;
    std::string key_id;
  };

  struct RemotePasswordRecord {
    Record record;
    std::string fingerprint;
  };

  enum class PendingRead {
    kNone,
    kApplyRemote,
    kPostApply,
  };

  // PasswordStoreInterface::Observer:
  void OnLoginsChanged(
      password_manager::PasswordStoreInterface *store,
      const password_manager::PasswordStoreChangeList &changes) override;
  void OnLoginsRetained(password_manager::PasswordStoreInterface *store,
                        const std::vector<password_manager::PasswordForm>
                            &retained_passwords) override;

  // PasswordStoreConsumer:
  void OnGetPasswordStoreResultsOrErrorFrom(
      password_manager::PasswordStoreInterface *store,
      password_manager::LoginsResultOrError results_or_error) override;

  void ReconcileRemotePasswords(
      const password_manager::LoginsResult &local_credentials);
  void PublishLocalMutations(const password_manager::LoginsResult &credentials);
  void PushRecords(std::vector<Record> records);
  void OnPushComplete(std::map<std::string, std::string> fingerprints, bool ok,
                      RecordsResult result, std::string error);
  void OnPullComplete(bool ok, RecordsResult result, std::string error);
  void OnRemoteRecordComplete();
  bool
  VerifyRemoteWrites(const password_manager::LoginsResult &local_credentials);
  void FinishReconcile();
  bool LoadState();
  bool SaveState() const;
  std::set<std::string>
  KeysFor(const password_manager::LoginsResult &credentials) const;

  scoped_refptr<password_manager::PasswordStoreInterface> profile_store_;
  std::unique_ptr<HeliumSyncClient> client_;
  std::string device_name_;
  base::FilePath state_path_;
  bool observing_ = false;
  bool pull_in_flight_ = false;
  bool reconciling_ = false;
  bool applying_remote_ = false;
  bool state_trusted_ = true;
  int pending_remote_writes_ = 0;
  PendingRead pending_read_ = PendingRead::kNone;
  std::set<std::string> known_keys_;
  std::set<std::string> blocked_remote_keys_;
  std::map<std::string, CredentialState> credential_state_;
  std::vector<RemotePasswordRecord> pending_remote_records_;
  std::map<std::string, RemotePasswordRecord> pending_verification_;
  int initial_empty_read_retries_ = 0;
  int post_apply_empty_read_retries_ = 0;
  int64_t pending_next_seq_ = 0;
  int64_t verified_sequence_ = 0;
  base::RepeatingCallback<void(int64_t)> verified_baseline_callback_;
  base::RepeatingTimer pull_timer_;
  base::WeakPtrFactory<HeliumPasswordSyncBridge> weak_factory_{this};
};

} // namespace helium_sync

#endif // COMPONENTS_HELIUM_SYNC_HELIUM_PASSWORD_SYNC_BRIDGE_H_
