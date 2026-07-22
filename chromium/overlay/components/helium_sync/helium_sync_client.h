// Copyright 2026 The Helium Authors

#ifndef COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_
#define COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
} // namespace network

namespace helium_sync {

// Records are plaintext only inside the browser process. The HTTP client maps
// them to/from authenticated ciphertext and never sends device_id or payload.
struct Record {
  int64_t seq = 0;
  int64_t revision = 0;
  int64_t expected_revision = 0;
  std::string kind;
  std::string key;
  bool deleted = false;
  std::string device_id;
  std::string key_id;
  std::string payload_json;
};

struct RecordsResult {
  std::vector<Record> records;
  int64_t next_seq = 0;
};

struct SealedPayload {
  std::string key_id;
  std::string nonce;
  std::string ciphertext;
};

class HeliumSyncClient {
public:
  using RecordsCallback = base::OnceCallback<void(bool ok, RecordsResult result,
                                                  std::string error)>;
  using StatusCallback = base::OnceCallback<void(bool ok, std::string error)>;

  HeliumSyncClient(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
      GURL base_url, std::string bearer_token,
      base::FilePath client_state_path);
  HeliumSyncClient(const HeliumSyncClient &) = delete;
  HeliumSyncClient &operator=(const HeliumSyncClient &) = delete;
  ~HeliumSyncClient();

  void Push(std::vector<Record> records, RecordsCallback callback);
  void Pull(int64_t since, std::vector<std::string> kinds,
            RecordsCallback callback);
  void Latest(std::vector<std::string> kinds, RecordsCallback callback);
  std::string_view device_id() const { return state_.device_id; }
  std::string_view enrollment_phase() const { return state_.phase; }
  bool AcknowledgeApplied(int64_t next_seq, std::string *error);
  bool ReloadEnrollmentState(std::string *error);
  void CompleteEnrollment(int64_t acknowledged_seq, StatusCallback callback);

  // Cookie rollback and other local durable data use the content keyring with a
  // separate AAD domain. The resulting value is safe to persist; plaintext is
  // never written by this helper.
  bool SealLocalPayload(std::string_view purpose, std::string_view plaintext,
                        SealedPayload *sealed, std::string *error) const;
  bool OpenLocalPayload(std::string_view purpose, const SealedPayload &sealed,
                        std::string *plaintext, std::string *error) const;

private:
  struct PaginationState;

  struct ClientState {
    std::string device_id;
    std::string role;
    std::string phase;
    std::string active_key_id;
    std::map<std::string, std::vector<uint8_t>> keys;
    std::vector<uint8_t> local_seal_key;
    int64_t sequence = 0;
  };

  bool LoadClientState(const base::FilePath &path);
  bool PersistStateProgress(int64_t sequence,
                            std::optional<std::string_view> phase,
                            std::string *error);
  bool EncryptRecord(const Record &plain, base::DictValue *opaque,
                     std::string *error) const;
  std::optional<RecordsResult> ParseRecordsObject(const base::DictValue &root,
                                                  std::string *error) const;
  std::optional<RecordsResult> ParseRecordsResponse(std::string_view body,
                                                    std::string *error) const;
  std::optional<RecordsResult>
  ParseRecordsPageResponse(std::string_view body, std::string *page_cursor,
                           std::string *error) const;
  void FetchRecordsPage(std::unique_ptr<PaginationState> state,
                        RecordsCallback callback);
  void OnRecordsPageComplete(network::SimpleURLLoader *loader,
                             std::unique_ptr<PaginationState> state,
                             RecordsCallback callback,
                             std::optional<std::string> body);
  void OnPushComplete(network::SimpleURLLoader *loader,
                      std::vector<Record> expected, RecordsCallback callback,
                      std::optional<std::string> body);
  void OnEnrollmentComplete(network::SimpleURLLoader *loader,
                            int64_t acknowledged_seq, StatusCallback callback,
                            std::optional<std::string> body);
  std::unique_ptr<network::SimpleURLLoader>
  MakeJSONRequest(GURL url, std::string method, std::string body);
  void RemoveLoader(network::SimpleURLLoader *loader);

  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  GURL base_url_;
  std::string bearer_token_;
  base::FilePath client_state_path_;
  ClientState state_;
  std::string state_error_;
  std::vector<std::unique_ptr<network::SimpleURLLoader>> loaders_;
  base::WeakPtrFactory<HeliumSyncClient> weak_factory_{this};
};

} // namespace helium_sync

#endif // COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_
