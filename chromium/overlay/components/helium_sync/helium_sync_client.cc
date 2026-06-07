// Copyright 2026 The Helium Authors

#include "components/helium_sync/helium_sync_client.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/values.h"
#include "net/base/load_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"

namespace helium_sync {
namespace {

constexpr char kContentType[] = "application/json";
constexpr int kMaxSyncResponseBytes = 5 * 1024 * 1024;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("helium_sync_local_daemon", R"(
      semantics {
        sender: "Helium sync local daemon client"
        description:
          "Sends user-enabled Helium browser sync records to a local daemon."
        trigger:
          "The user has enabled helium-sync integration in their Helium fork."
        data:
          "Browser records serialized by Chromium APIs. Payload encryption is "
          "performed by the local daemon."
        destination: LOCAL
        internal {
          contacts {
            email: "security@imput.net"
          }
        }
        user_data {
          type: ACCESS_TOKEN
          type: SENSITIVE_URL
          type: WEB_CONTENT
        }
        last_reviewed: "2026-06-06"
      }
      policy {
        cookies_allowed: NO
        setting:
          "This client is only active when the user enables helium-sync in the "
          "Helium fork and configures the local daemon token."
        policy_exception_justification:
          "Not implemented as an enterprise policy."
      })");

std::optional<base::DictValue> RecordToValue(const Record& record) {
  std::optional<base::Value> payload = base::JSONReader::Read(
      record.payload_json.empty() ? "{}" : record.payload_json,
      base::JSON_PARSE_RFC);
  if (!payload) {
    return std::nullopt;
  }

  base::DictValue value;
  value.Set("kind", record.kind);
  value.Set("key", record.key);
  if (record.deleted) {
    value.Set("deleted", true);
  }
  if (!record.origin_device.empty()) {
    value.Set("origin_device", record.origin_device);
  }
  value.Set("payload", std::move(*payload));
  return value;
}

std::string RecordsPath(std::string_view path,
                        int64_t since,
                        const std::vector<std::string>& kinds,
                        bool include_deleted) {
  std::string out(path);
  bool first = true;
  auto append_param = [&](std::string_view key, std::string_view value) {
    out += first ? "?" : "&";
    first = false;
    out += key;
    out += "=";
    out += base::EscapeQueryParamValue(value, true);
  };
  if (since > 0) {
    append_param("since", base::NumberToString(since));
  }
  for (const auto& kind : kinds) {
    if (!kind.empty()) {
      append_param("kind", kind);
    }
  }
  if (include_deleted) {
    append_param("include_deleted", "true");
  }
  return out;
}

}  // namespace

HeliumSyncClient::HeliumSyncClient(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
    GURL base_url,
    std::string bearer_token,
    std::string device_name)
    : url_loader_factory_(std::move(url_loader_factory)),
      base_url_(std::move(base_url)),
      bearer_token_(std::move(bearer_token)),
      device_name_(std::move(device_name)) {}

HeliumSyncClient::~HeliumSyncClient() = default;

void HeliumSyncClient::Push(std::vector<Record> records,
                            PushCallback callback) {
  base::DictValue body;
  body.Set("device", device_name_);
  base::ListValue values;
  for (const auto& record : records) {
    std::optional<base::DictValue> value = RecordToValue(record);
    if (!value) {
      std::move(callback).Run(false, "failed to encode record payload JSON");
      return;
    }
    values.Append(std::move(*value));
  }
  body.Set("records", std::move(values));

  std::string body_json;
  if (!base::JSONWriter::Write(body, &body_json)) {
    std::move(callback).Run(false, "failed to encode push JSON");
    return;
  }

  auto loader = MakeJSONRequest(base_url_.Resolve("/v1/records/push"), "POST",
                                std::move(body_json));
  auto* loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&HeliumSyncClient::OnPushComplete,
                     weak_factory_.GetWeakPtr(), std::move(callback)),
      1024 * 1024);
}

void HeliumSyncClient::Pull(int64_t since,
                            std::vector<std::string> kinds,
                            PullCallback callback) {
  auto loader = MakeJSONRequest(
      base_url_.Resolve(RecordsPath("/v1/records/pull", since, kinds,
                                    /*include_deleted=*/false)),
      "GET", std::string());
  auto* loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&HeliumSyncClient::OnPullComplete,
                     weak_factory_.GetWeakPtr(), std::move(callback)),
      kMaxSyncResponseBytes);
}

void HeliumSyncClient::Latest(std::vector<std::string> kinds,
                              bool include_deleted,
                              PullCallback callback) {
  auto loader =
      MakeJSONRequest(base_url_.Resolve(RecordsPath("/v1/records/latest", 0,
                                                    kinds, include_deleted)),
                      "GET", std::string());
  auto* loader_ptr = loader.get();
  loaders_.push_back(std::move(loader));
  loader_ptr->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&HeliumSyncClient::OnPullComplete,
                     weak_factory_.GetWeakPtr(), std::move(callback)),
      kMaxSyncResponseBytes);
}

void HeliumSyncClient::OnPushComplete(PushCallback callback,
                                      std::optional<std::string> body) {
  if (!body) {
    std::move(callback).Run(false, "push failed");
    return;
  }
  std::move(callback).Run(true, std::string());
}

void HeliumSyncClient::OnPullComplete(PullCallback callback,
                                      std::optional<std::string> body) {
  if (!body) {
    std::move(callback).Run(false, std::string(), "pull failed");
    return;
  }
  std::move(callback).Run(true, *body, std::string());
}

std::unique_ptr<network::SimpleURLLoader> HeliumSyncClient::MakeJSONRequest(
    GURL url,
    std::string method,
    std::string body) {
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = std::move(url);
  request->method = std::move(method);
  request->load_flags = net::LOAD_BYPASS_CACHE | net::LOAD_DISABLE_CACHE;
  request->headers.SetHeader("Authorization", "Bearer " + bearer_token_);
  auto loader =
      network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
  if (!body.empty()) {
    loader->AttachStringForUpload(std::move(body), kContentType);
  }
  return loader;
}

}  // namespace helium_sync
