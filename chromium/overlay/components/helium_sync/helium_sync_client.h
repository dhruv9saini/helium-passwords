// Copyright 2026 The Helium Authors

#ifndef COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_
#define COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network

namespace helium_sync {

struct Record {
  std::string kind;
  std::string key;
  bool deleted = false;
  std::string origin_device;
  std::string payload_json;
};

class HeliumSyncClient {
 public:
  using PushCallback = base::OnceCallback<void(bool ok, std::string error)>;
  using PullCallback = base::OnceCallback<
      void(bool ok, std::string response_json, std::string error)>;

  HeliumSyncClient(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
      GURL base_url,
      std::string bearer_token,
      std::string device_name);
  HeliumSyncClient(const HeliumSyncClient&) = delete;
  HeliumSyncClient& operator=(const HeliumSyncClient&) = delete;
  ~HeliumSyncClient();

  void Push(std::vector<Record> records, PushCallback callback);
  void Pull(int64_t since,
            std::vector<std::string> kinds,
            PullCallback callback);
  void Latest(std::vector<std::string> kinds,
              bool include_deleted,
              PullCallback callback);

 private:
  void OnPushComplete(PushCallback callback, std::optional<std::string> body);
  void OnPullComplete(PullCallback callback, std::optional<std::string> body);
  std::unique_ptr<network::SimpleURLLoader> MakeJSONRequest(GURL url,
                                                            std::string method,
                                                            std::string body);

  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  GURL base_url_;
  std::string bearer_token_;
  std::string device_name_;
  std::vector<std::unique_ptr<network::SimpleURLLoader>> loaders_;
  base::WeakPtrFactory<HeliumSyncClient> weak_factory_{this};
};

}  // namespace helium_sync

#endif  // COMPONENTS_HELIUM_SYNC_HELIUM_SYNC_CLIENT_H_
