// Copyright 2026 The Helium Authors

#include "components/helium_sync/helium_password_sync_bridge.h"

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>

#include "base/base64.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "build/build_config.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_store/password_store_change.h"
#include "components/password_manager/core/browser/password_store/password_form_converters.h"
#include "components/password_manager/core/browser/sync/password_proto_utils.h"
#include "components/sync/protocol/password_specifics.pb.h"
#include "crypto/sha2.h"

#if BUILDFLAG(IS_ANDROID)
#include <android/log.h>
#endif

#if __has_include( \
    "components/password_manager/core/browser/password_store/stored_credential.h")
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#define HELIUM_SYNC_HAS_STORED_CREDENTIAL 1
#else
#define HELIUM_SYNC_HAS_STORED_CREDENTIAL 0
#endif

namespace helium_sync {
namespace {

constexpr char kPasswordKind[] = "passwords";
constexpr char kSimplePayloadFormat[] = "helium-password-v1";
constexpr char kChromiumSpecificsPayloadFormat[] =
    "chromium-password-specifics-data-v1";

#if BUILDFLAG(IS_ANDROID)
void AndroidStatusLog(const std::string& message) {
  __android_log_write(ANDROID_LOG_WARN, "HeliumSync", message.c_str());
}
#else
void AndroidStatusLog(const std::string&) {}
#endif

using Credential = password_manager::LoginsResult::value_type;

const Credential& ChangeCredential(
    const password_manager::PasswordStoreChange& change) {
#if HELIUM_SYNC_HAS_STORED_CREDENTIAL
  return change.credential();
#else
  return change.form();
#endif
}

Credential CredentialFromSpecifics(
    const sync_pb::PasswordSpecificsData& specifics) {
#if HELIUM_SYNC_HAS_STORED_CREDENTIAL
  Credential credential =
      password_manager::StoredCredentialFromSpecifics(specifics);
#else
  Credential credential = password_manager::PasswordFromSpecifics(specifics);
#endif
  credential.in_store = password_manager::PasswordForm::Store::kProfileStore;
  return credential;
}

std::string PasswordRecordKeyForValues(std::string_view signon_realm,
                                       std::string_view url,
                                       const std::u16string& username) {
  std::string material;
  material.append(signon_realm);
  material.push_back('\0');
  material.append(url);
  material.push_back('\0');
  material.append(base::UTF16ToUTF8(username));
  return "credential/" +
         base::HexEncodeLower(crypto::SHA256HashString(material));
}

std::string SignonRealmForCredential(const Credential& credential) {
  if (!credential.signon_realm.empty()) {
    return credential.signon_realm;
  }
  if (credential.url.is_valid()) {
    return credential.url.DeprecatedGetOriginAsURL().spec();
  }
  return std::string();
}

std::string UrlForCredential(const Credential& credential) {
  if (credential.url.is_valid()) {
    return credential.url.spec();
  }
  return SignonRealmForCredential(credential);
}

std::string PasswordRecordKey(const Credential& credential) {
  return PasswordRecordKeyForValues(SignonRealmForCredential(credential),
                                    UrlForCredential(credential),
                                    credential.username_value);
}

std::u16string NoteForCredential(const Credential& credential) {
  for (const auto& note : credential.notes) {
    if (!note.value.empty()) {
      return note.value;
    }
  }
  return std::u16string();
}

std::optional<std::string> PasswordPayloadJSON(const Credential& credential) {
  base::DictValue payload;
  payload.Set("format", kSimplePayloadFormat);
  payload.Set("url", UrlForCredential(credential));
  payload.Set("signon_realm", SignonRealmForCredential(credential));
  payload.Set("username", base::UTF16ToUTF8(credential.username_value));
  payload.Set("password", base::UTF16ToUTF8(credential.password_value));
  payload.Set("note", base::UTF16ToUTF8(NoteForCredential(credential)));

  std::string payload_json;
  if (!base::JSONWriter::Write(payload, &payload_json)) {
    return std::nullopt;
  }
  return payload_json;
}

std::optional<Credential> PayloadToCredential(const base::DictValue& payload) {
  const std::string* format = payload.FindString("format");
  if (!format) {
    return std::nullopt;
  }
  if (*format == kSimplePayloadFormat) {
    const std::string* url_string = payload.FindString("url");
    const std::string* username = payload.FindString("username");
    const std::string* password = payload.FindString("password");
    if (!url_string || !username || !password) {
      return std::nullopt;
    }
    GURL url(*url_string);
    if (!url.is_valid()) {
      return std::nullopt;
    }

    Credential credential;
    credential.scheme = password_manager::PasswordForm::Scheme::kHtml;
    credential.signon_realm = url.DeprecatedGetOriginAsURL().spec();
    if (const std::string* signon_realm =
            payload.FindString("signon_realm")) {
      if (!signon_realm->empty()) {
        credential.signon_realm = *signon_realm;
      }
    }
    credential.url = std::move(url);
    credential.username_value = base::UTF8ToUTF16(*username);
    credential.password_value = base::UTF8ToUTF16(*password);
    credential.in_store = password_manager::PasswordForm::Store::kProfileStore;
    credential.type = password_manager::PasswordForm::Type::kImported;
    credential.date_created = base::Time::Now();
    credential.date_password_modified = credential.date_created;
    if (const std::string* note = payload.FindString("note");
        note && !note->empty()) {
      credential.notes.emplace_back(base::UTF8ToUTF16(*note),
                                    credential.date_created);
    }
    return credential;
  }

  if (*format != kChromiumSpecificsPayloadFormat) {
    return std::nullopt;
  }
  const std::string* encoded =
      payload.FindString("password_specifics_data_b64");
  if (!encoded) {
    return std::nullopt;
  }
  std::string serialized;
  if (!base::Base64Decode(*encoded, &serialized)) {
    return std::nullopt;
  }
  sync_pb::PasswordSpecificsData specifics;
  if (!specifics.ParseFromString(serialized)) {
    return std::nullopt;
  }
  return CredentialFromSpecifics(specifics);
}

std::optional<Record> UpsertRecordForCredential(const Credential& credential) {
  std::optional<std::string> payload_json = PasswordPayloadJSON(credential);
  if (!payload_json) {
    return std::nullopt;
  }
  Record record;
  record.kind = kPasswordKind;
  record.key = PasswordRecordKey(credential);
  record.payload_json = std::move(*payload_json);
  return record;
}

}  // namespace

HeliumPasswordSyncBridge::HeliumPasswordSyncBridge(
    scoped_refptr<password_manager::PasswordStoreInterface> profile_store,
    std::unique_ptr<HeliumSyncClient> client,
    std::string device_name)
    : profile_store_(std::move(profile_store)),
      client_(std::move(client)),
      device_name_(std::move(device_name)) {}

HeliumPasswordSyncBridge::~HeliumPasswordSyncBridge() {
  Stop();
}

void HeliumPasswordSyncBridge::Start() {
  if (!profile_store_ || !client_ || observing_) {
    return;
  }
  observing_ = true;
  profile_store_->AddObserver(this);
  RequestInitialExport();
}

void HeliumPasswordSyncBridge::Stop() {
  pull_timer_.Stop();
  if (observing_ && profile_store_) {
    profile_store_->RemoveObserver(this);
  }
  observing_ = false;
  weak_factory_.InvalidateWeakPtrs();
}

void HeliumPasswordSyncBridge::PullAndApply() {
  if (!profile_store_ || !client_ || pull_in_flight_) {
    return;
  }
  pull_in_flight_ = true;
  client_->Latest({kPasswordKind}, /*include_deleted=*/false,
                  base::BindOnce(&HeliumPasswordSyncBridge::OnPullComplete,
                                 weak_factory_.GetWeakPtr()));
}

void HeliumPasswordSyncBridge::RequestInitialExport() {
  if (!profile_store_) {
    return;
  }
  pending_read_ = PendingRead::kInitialExport;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::RequestPostApplyExport() {
  if (!profile_store_) {
    return;
  }
  pending_read_ = PendingRead::kPostApplyExport;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::OnLoginsChanged(
    password_manager::PasswordStoreInterface* store,
    const password_manager::PasswordStoreChangeList& changes) {
  if (store != profile_store_.get() || suppress_local_changes_ > 0) {
    return;
  }

  std::vector<Record> records;
  for (const auto& change : changes) {
    const Credential& credential = ChangeCredential(change);
    if (change.type() == password_manager::PasswordStoreChange::REMOVE) {
      known_keys_.erase(PasswordRecordKey(credential));
      continue;
    }
    std::optional<Record> record = UpsertRecordForCredential(credential);
    if (!record) {
      continue;
    }
    known_keys_.insert(record->key);
    records.push_back(std::move(*record));
  }
  PushRecords(std::move(records));
}

void HeliumPasswordSyncBridge::OnLoginsRetained(
    password_manager::PasswordStoreInterface* store,
    const password_manager::LoginsResult& retained_credentials) {
  if (store != profile_store_.get() || suppress_local_changes_ > 0) {
    return;
  }

  known_keys_ = KeysFor(retained_credentials);
}

void HeliumPasswordSyncBridge::OnGetPasswordStoreResultsOrErrorFrom(
    password_manager::PasswordStoreInterface* store,
    password_manager::LoginsResultOrError results_or_error) {
  if (store != profile_store_.get()) {
    return;
  }
  PendingRead pending = pending_read_;
  pending_read_ = PendingRead::kNone;

  auto* credentials =
      std::get_if<password_manager::LoginsResult>(&results_or_error);
  if (!credentials) {
    LOG(WARNING) << "Helium password sync read failed for pending "
                 << static_cast<int>(pending);
    AndroidStatusLog("password read failed pending=" +
                     base::NumberToString(static_cast<int>(pending)));
    return;
  }
  LOG(WARNING) << "Helium password sync read " << credentials->size()
               << " credentials for pending " << static_cast<int>(pending);
  AndroidStatusLog("password read count=" +
                   base::NumberToString(credentials->size()));

  switch (pending) {
    case PendingRead::kInitialExport:
#if BUILDFLAG(IS_ANDROID)
      if (credentials->empty() && initial_empty_read_retries_ < 3) {
        initial_empty_read_retries_++;
        AndroidStatusLog("password initial empty retry=" +
                         base::NumberToString(initial_empty_read_retries_));
        base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
            FROM_HERE,
            base::BindOnce(&HeliumPasswordSyncBridge::RequestInitialExport,
                           weak_factory_.GetWeakPtr()),
            base::Seconds(1));
        return;
      }
#endif
      initial_empty_read_retries_ = 0;
      ExportInitialPasswords(*credentials);
      PullAndApply();
      pull_timer_.Start(
          FROM_HERE, base::Seconds(30),
          base::BindRepeating(&HeliumPasswordSyncBridge::PullAndApply,
                              weak_factory_.GetWeakPtr()));
      break;
    case PendingRead::kApplyRemote:
      ApplyRemotePasswords(*credentials);
      break;
    case PendingRead::kPostApplyExport:
#if BUILDFLAG(IS_ANDROID)
      if (credentials->empty() && post_apply_empty_read_retries_ < 3) {
        post_apply_empty_read_retries_++;
        AndroidStatusLog("password post-apply empty retry=" +
                         base::NumberToString(post_apply_empty_read_retries_));
        base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
            FROM_HERE,
            base::BindOnce(&HeliumPasswordSyncBridge::RequestPostApplyExport,
                           weak_factory_.GetWeakPtr()),
            base::Seconds(2));
        return;
      }
#endif
      post_apply_empty_read_retries_ = 0;
      ExportInitialPasswords(*credentials);
      break;
    case PendingRead::kNone:
      break;
  }
}

void HeliumPasswordSyncBridge::ExportInitialPasswords(
    const password_manager::LoginsResult& credentials) {
  known_keys_ = KeysFor(credentials);
  std::vector<Record> records;
  for (const auto& credential : credentials) {
    std::optional<Record> record = UpsertRecordForCredential(credential);
    if (record) {
      records.push_back(std::move(*record));
    }
  }
  PushRecords(std::move(records));
}

void HeliumPasswordSyncBridge::ApplyRemotePasswords(
    const password_manager::LoginsResult& local_credentials) {
  std::map<std::string, const Credential*> local_by_key;
  for (const auto& credential : local_credentials) {
    local_by_key[PasswordRecordKey(credential)] = &credential;
  }

  for (const auto& remote : pending_remote_records_) {
    const auto existing = local_by_key.find(remote.key);
    if (remote.origin_device == device_name_ &&
        existing != local_by_key.end()) {
      continue;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(remote.payload_json, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      continue;
    }
    std::optional<Credential> credential =
        PayloadToCredential(parsed->GetDict());
    if (!credential) {
      continue;
    }

    if (existing == local_by_key.end()) {
      suppress_local_changes_ += 2;
      profile_store_->UpdateLogin(
          password_manager::CloneStoredCredential(*credential),
          base::BindOnce(
              &HeliumPasswordSyncBridge::AddRemoteLoginAfterUpdate,
              weak_factory_.GetWeakPtr(), std::move(*credential)));
    } else {
      suppress_local_changes_++;
      profile_store_->UpdateLogin(
          std::move(*credential),
          base::BindOnce(
              &HeliumPasswordSyncBridge::OnRemoteWriteAndExportComplete,
                         weak_factory_.GetWeakPtr()));
    }
    known_keys_.insert(remote.key);
  }
  pending_remote_records_.clear();
}

void HeliumPasswordSyncBridge::PushRecords(std::vector<Record> records) {
  if (records.empty() || !client_) {
    return;
  }
  LOG(WARNING) << "Helium password sync pushing " << records.size()
               << " records as " << device_name_;
  AndroidStatusLog("password pushing count=" +
                   base::NumberToString(records.size()));
  for (auto& record : records) {
    record.origin_device = device_name_;
  }
  client_->Push(std::move(records),
                base::BindOnce(&HeliumPasswordSyncBridge::OnPushComplete,
                               weak_factory_.GetWeakPtr()));
}

void HeliumPasswordSyncBridge::OnPushComplete(bool ok, std::string error) {
  if (!ok) {
    LOG(WARNING) << "Helium password sync push failed: " << error;
    AndroidStatusLog("password push failed " + error);
    return;
  }
  LOG(WARNING) << "Helium password sync push completed";
  AndroidStatusLog("password push completed");
}

void HeliumPasswordSyncBridge::OnPullComplete(bool ok,
                                              std::string response_json,
                                              std::string error) {
  pull_in_flight_ = false;
  if (!ok) {
    LOG(WARNING) << "Helium password sync pull failed: " << error;
    AndroidStatusLog("password pull failed " + error);
    return;
  }

  std::optional<base::Value> root =
      base::JSONReader::Read(response_json, base::JSON_PARSE_RFC);
  if (!root || !root->is_dict()) {
    return;
  }
  const base::ListValue* records = root->GetDict().FindList("records");
  if (!records) {
    LOG(WARNING) << "Helium password sync pull had no records list";
    AndroidStatusLog("password pull missing records");
    return;
  }

  pending_remote_records_.clear();
  for (const base::Value& item : *records) {
    if (!item.is_dict()) {
      continue;
    }
    const base::DictValue& dict = item.GetDict();
    const std::string* kind = dict.FindString("kind");
    const std::string* key = dict.FindString("key");
    if (!kind || *kind != kPasswordKind || !key) {
      continue;
    }
    RemotePasswordRecord record;
    record.key = *key;
    if (dict.FindBool("deleted").value_or(false)) {
      continue;
    }
    if (const std::string* origin_device = dict.FindString("origin_device")) {
      record.origin_device = *origin_device;
    }
    if (const base::DictValue* payload = dict.FindDict("payload")) {
      if (!base::JSONWriter::Write(*payload, &record.payload_json)) {
        continue;
      }
    } else {
      record.payload_json = "{}";
    }
    pending_remote_records_.push_back(std::move(record));
  }

  if (pending_remote_records_.empty()) {
    LOG(WARNING) << "Helium password sync pull found no password records";
    AndroidStatusLog("password pull empty");
    return;
  }
  LOG(WARNING) << "Helium password sync pulled "
               << pending_remote_records_.size() << " password records";
  AndroidStatusLog("password pulled count=" +
                   base::NumberToString(pending_remote_records_.size()));
  pending_read_ = PendingRead::kApplyRemote;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::AddRemoteLoginAfterUpdate(
    Credential credential) {
  OnRemoteWriteComplete();
  if (!profile_store_) {
    OnRemoteWriteComplete();
    return;
  }
  profile_store_->AddLogin(
      std::move(credential),
      base::BindOnce(&HeliumPasswordSyncBridge::OnRemoteWriteAndExportComplete,
                     weak_factory_.GetWeakPtr()));
}

void HeliumPasswordSyncBridge::OnRemoteWriteAndExportComplete() {
  OnRemoteWriteComplete();
  if (!profile_store_ || suppress_local_changes_ > 0) {
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&HeliumPasswordSyncBridge::RequestPostApplyExport,
                     weak_factory_.GetWeakPtr()),
      base::Seconds(2));
}

void HeliumPasswordSyncBridge::OnRemoteWriteComplete() {
  if (suppress_local_changes_ > 0) {
    suppress_local_changes_--;
  }
}

std::set<std::string> HeliumPasswordSyncBridge::KeysFor(
    const password_manager::LoginsResult& credentials) const {
  std::set<std::string> keys;
  for (const auto& credential : credentials) {
    keys.insert(PasswordRecordKey(credential));
  }
  return keys;
}

}  // namespace helium_sync
