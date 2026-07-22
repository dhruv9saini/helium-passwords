// Copyright 2026 The Helium Authors

#include "components/helium_sync/helium_password_sync_bridge.h"

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>

#include "base/base64.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "build/build_config.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_store/password_store_change.h"
#include "components/password_manager/core/browser/sync/password_proto_utils.h"
#include "components/sync/protocol/password_specifics.pb.h"
#include "crypto/sha2.h"

#if BUILDFLAG(IS_ANDROID)
#include <android/log.h>
#endif

namespace helium_sync {
namespace {

constexpr char kPasswordKind[] = "passwords";
constexpr char kChromiumSpecificsPayloadFormat[] =
    "chromium-password-specifics-data-v1";
constexpr int kPasswordStateSchema = 3;

#if BUILDFLAG(IS_ANDROID)
void AndroidStatusLog(const std::string &message) {
  __android_log_write(ANDROID_LOG_WARN, "HeliumSync", message.c_str());
}
#else
void AndroidStatusLog(const std::string &) {}
#endif

using Credential = password_manager::PasswordForm;

const Credential &
ChangeCredential(const password_manager::PasswordStoreChange &change) {
  return change.form();
}

Credential
CredentialFromSpecifics(const sync_pb::PasswordSpecificsData &specifics) {
  Credential credential = password_manager::PasswordFromSpecifics(specifics);
  credential.in_store = password_manager::PasswordForm::Store::kProfileStore;
  return credential;
}

std::string PasswordRecordKeyForValues(std::string_view signon_realm,
                                       std::string_view url,
                                       const std::u16string &username) {
  std::string material;
  material.append(signon_realm);
  material.push_back('\0');
  material.append(url);
  material.push_back('\0');
  material.append(base::UTF16ToUTF8(username));
  return "credential/" +
         base::HexEncodeLower(crypto::SHA256HashString(material));
}

template <typename CredentialLike>
std::string SignonRealmForCredential(const CredentialLike &credential) {
  if (!credential.signon_realm.empty()) {
    return credential.signon_realm;
  }
  if (credential.url.is_valid()) {
    return credential.url.DeprecatedGetOriginAsURL().spec();
  }
  return std::string();
}

template <typename CredentialLike>
std::string UrlForCredential(const CredentialLike &credential) {
  if (credential.url.is_valid()) {
    return credential.url.spec();
  }
  return SignonRealmForCredential(credential);
}

std::string PasswordRecordKey(const Credential &credential) {
  return PasswordRecordKeyForValues(SignonRealmForCredential(credential),
                                    UrlForCredential(credential),
                                    credential.username_value);
}

std::string
PasswordRecordKeyForForm(const password_manager::PasswordForm &credential) {
  return PasswordRecordKeyForValues(SignonRealmForCredential(credential),
                                    UrlForCredential(credential),
                                    credential.username_value);
}

std::optional<std::string> PasswordPayloadJSON(const Credential &credential) {
  sync_pb::PasswordSpecificsData specifics =
      password_manager::SpecificsDataFromPassword(credential,
                                                  /*base_password_data=*/{});
  std::string serialized;
  if (!specifics.SerializeToString(&serialized)) {
    return std::nullopt;
  }

  base::DictValue payload;
  payload.Set("format", kChromiumSpecificsPayloadFormat);
  payload.Set("password_specifics_data_b64", base::Base64Encode(serialized));

  std::string payload_json;
  if (!base::JSONWriter::Write(payload, &payload_json)) {
    return std::nullopt;
  }
  return payload_json;
}

std::optional<Credential> PayloadToCredential(const base::DictValue &payload) {
  const std::string *format = payload.FindString("format");
  if (!format) {
    return std::nullopt;
  }
  if (*format != kChromiumSpecificsPayloadFormat) {
    return std::nullopt;
  }
  const std::string *encoded =
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
  Credential credential = CredentialFromSpecifics(specifics);
  if (credential.signon_realm.empty() ||
      (specifics.has_origin() && !specifics.origin().empty() &&
       !credential.url.is_valid())) {
    return std::nullopt;
  }
  return credential;
}

std::optional<Record> UpsertRecordForCredential(const Credential &credential) {
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

std::string ContentFingerprint(std::string_view payload_json) {
  return base::HexEncodeLower(crypto::SHA256HashString(payload_json));
}

} // namespace

HeliumPasswordSyncBridge::HeliumPasswordSyncBridge(
    scoped_refptr<password_manager::PasswordStoreInterface> profile_store,
    std::unique_ptr<HeliumSyncClient> client, std::string device_name,
    base::FilePath state_path)
    : profile_store_(std::move(profile_store)), client_(std::move(client)),
      device_name_(std::move(device_name)), state_path_(std::move(state_path)) {
}

HeliumPasswordSyncBridge::~HeliumPasswordSyncBridge() { Stop(); }

void HeliumPasswordSyncBridge::Start() {
  if (!profile_store_ || !client_ || observing_) {
    return;
  }
  state_trusted_ = LoadState();
  if (!state_trusted_) {
    if (base::PathExists(state_path_) || !SaveState()) {
      LOG(WARNING)
          << "Helium password sync disabled: state is invalid or unwritable";
      AndroidStatusLog("password state invalid or unwritable; fail closed");
      return;
    }
    state_trusted_ = true;
  }
  pull_timer_.Start(FROM_HERE, base::Seconds(30),
                    base::BindRepeating(&HeliumPasswordSyncBridge::PullAndApply,
                                        weak_factory_.GetWeakPtr()));
  PullAndApply();
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
  if (!profile_store_ || !client_ || pull_in_flight_ || reconciling_) {
    return;
  }
  pull_in_flight_ = true;
  reconciling_ = true;
  client_->Latest({kPasswordKind},
                  base::BindOnce(&HeliumPasswordSyncBridge::OnPullComplete,
                                 weak_factory_.GetWeakPtr()));
}

void HeliumPasswordSyncBridge::RequestReconcileRead() {
  if (!profile_store_) {
    return;
  }
  pending_read_ = PendingRead::kApplyRemote;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::RequestPostApplyRead() {
  if (!profile_store_) {
    return;
  }
  pending_read_ = PendingRead::kPostApply;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::OnLoginsChanged(
    password_manager::PasswordStoreInterface *store,
    const password_manager::PasswordStoreChangeList &changes) {
  if (store != profile_store_.get() || reconciling_ || applying_remote_) {
    return;
  }

  std::vector<Record> records;
  for (const auto &change : changes) {
    const Credential &credential = ChangeCredential(change);
    if (change.type() == password_manager::PasswordStoreChange::REMOVE) {
      Record tombstone;
      tombstone.kind = kPasswordKind;
      tombstone.key = PasswordRecordKey(credential);
      tombstone.deleted = true;
      tombstone.payload_json = "{}";
      records.push_back(std::move(tombstone));
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
    password_manager::PasswordStoreInterface *store,
    const std::vector<password_manager::PasswordForm> &retained_passwords) {
  if (store != profile_store_.get() || reconciling_ || applying_remote_) {
    return;
  }

  std::set<std::string> retained_keys;
  for (const auto &credential : retained_passwords) {
    retained_keys.insert(PasswordRecordKeyForForm(credential));
  }
  known_keys_ = std::move(retained_keys);
}

void HeliumPasswordSyncBridge::OnGetPasswordStoreResultsOrErrorFrom(
    password_manager::PasswordStoreInterface *store,
    password_manager::LoginsResultOrError results_or_error) {
  if (store != profile_store_.get()) {
    return;
  }
  PendingRead pending = pending_read_;
  pending_read_ = PendingRead::kNone;

  auto *credentials =
      std::get_if<password_manager::LoginsResult>(&results_or_error);
  if (!credentials) {
    LOG(WARNING) << "Helium password sync read failed for pending "
                 << static_cast<int>(pending);
    AndroidStatusLog("password read failed pending=" +
                     base::NumberToString(static_cast<int>(pending)));
    reconciling_ = false;
    return;
  }
  LOG(WARNING) << "Helium password sync read " << credentials->size()
               << " credentials for pending " << static_cast<int>(pending);
  AndroidStatusLog("password read count=" +
                   base::NumberToString(credentials->size()));

  switch (pending) {
  case PendingRead::kApplyRemote:
#if BUILDFLAG(IS_ANDROID)
    if (credentials->empty() && initial_empty_read_retries_ < 3) {
      initial_empty_read_retries_++;
      AndroidStatusLog("password reconcile empty retry=" +
                       base::NumberToString(initial_empty_read_retries_));
      base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE,
          base::BindOnce(&HeliumPasswordSyncBridge::RequestReconcileRead,
                         weak_factory_.GetWeakPtr()),
          base::Seconds(1));
      return;
    }
#endif
    initial_empty_read_retries_ = 0;
    ReconcileRemotePasswords(*credentials);
    break;
  case PendingRead::kPostApply:
#if BUILDFLAG(IS_ANDROID)
    if (credentials->empty() && post_apply_empty_read_retries_ < 3) {
      post_apply_empty_read_retries_++;
      AndroidStatusLog("password post-apply empty retry=" +
                       base::NumberToString(post_apply_empty_read_retries_));
      base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE,
          base::BindOnce(&HeliumPasswordSyncBridge::RequestPostApplyRead,
                         weak_factory_.GetWeakPtr()),
          base::Seconds(2));
      return;
    }
#endif
    post_apply_empty_read_retries_ = 0;
    if (!VerifyRemoteWrites(*credentials)) {
      LOG(WARNING) << "Helium password sync post-write verification failed";
      AndroidStatusLog("password post-write verification failed");
      reconciling_ = false;
      return;
    }
    PublishLocalMutations(*credentials);
    FinishReconcile();
    break;
  case PendingRead::kNone:
    break;
  }
}

void HeliumPasswordSyncBridge::ReconcileRemotePasswords(
    const password_manager::LoginsResult &local_credentials) {
  std::map<std::string, const Credential *> local_by_key;
  for (const auto &credential : local_credentials) {
    local_by_key[PasswordRecordKey(credential)] = &credential;
  }

  // Validate the complete remote batch and detect conflicts before issuing a
  // single PasswordStore write. A malformed later record must not leave a
  // partially applied generation that could then be acknowledged.
  for (const auto &remote : pending_remote_records_) {
    const Record &record = remote.record;
    const auto state = credential_state_.find(record.key);
    if (state != credential_state_.end() &&
        record.revision <= state->second.revision) {
      continue;
    }
    const auto existing = local_by_key.find(record.key);
    if (state != credential_state_.end()) {
      bool local_matches_baseline = false;
      if (state->second.deleted) {
        local_matches_baseline = existing == local_by_key.end();
      } else if (existing != local_by_key.end()) {
        std::optional<std::string> local_payload =
            PasswordPayloadJSON(*existing->second);
        local_matches_baseline =
            local_payload &&
            ContentFingerprint(*local_payload) == state->second.fingerprint;
      }
      if (!local_matches_baseline) {
        blocked_remote_keys_.insert(record.key);
        continue;
      }
    }
    if (!record.deleted) {
      std::optional<base::Value> parsed =
          base::JSONReader::Read(record.payload_json, base::JSON_PARSE_RFC);
      std::optional<Credential> credential =
          parsed && parsed->is_dict()
              ? PayloadToCredential(parsed->GetDict())
              : std::nullopt;
      if (!credential || PasswordRecordKey(*credential) != record.key) {
        blocked_remote_keys_.insert(record.key);
      }
    }
  }
  if (!blocked_remote_keys_.empty()) {
    pending_remote_records_.clear();
    LOG(WARNING) << "Helium password sync blocked a malformed or concurrent "
                    "remote batch before applying it";
    AndroidStatusLog("password reconciliation blocked before apply");
    reconciling_ = false;
    return;
  }

  applying_remote_ = true;
  for (const auto &remote : pending_remote_records_) {
    const Record &record = remote.record;
    const auto state = credential_state_.find(record.key);
    if (state != credential_state_.end() &&
        record.revision <= state->second.revision) {
      continue;
    }
    const auto existing = local_by_key.find(record.key);
    if (state != credential_state_.end() &&
        record.revision > state->second.revision) {
      bool local_matches_baseline = false;
      if (state->second.deleted) {
        local_matches_baseline = existing == local_by_key.end();
      } else if (existing != local_by_key.end()) {
        std::optional<std::string> local_payload =
            PasswordPayloadJSON(*existing->second);
        local_matches_baseline =
            local_payload &&
            ContentFingerprint(*local_payload) == state->second.fingerprint;
      }
      if (!local_matches_baseline) {
        blocked_remote_keys_.insert(record.key);
        LOG(WARNING) << "Helium password sync stopped a concurrent local and "
                        "remote mutation for "
                     << record.key;
        continue;
      }
    }
    if (record.deleted) {
      if (existing == local_by_key.end()) {
        credential_state_[record.key] = {std::string(), record.seq,
                                         record.revision, true, record.key_id};
        known_keys_.erase(record.key);
        continue;
      }
      pending_verification_[record.key] = remote;
      pending_remote_writes_++;
      profile_store_->RemoveLogin(
          *existing->second,
          base::BindOnce(&HeliumPasswordSyncBridge::OnRemoteRecordComplete,
                         weak_factory_.GetWeakPtr()));
      continue;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(record.payload_json, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      blocked_remote_keys_.insert(record.key);
      continue;
    }
    std::optional<Credential> credential =
        PayloadToCredential(parsed->GetDict());
    if (!credential || PasswordRecordKey(*credential) != record.key) {
      blocked_remote_keys_.insert(record.key);
      continue;
    }
    std::optional<std::string> canonical_payload =
        PasswordPayloadJSON(*credential);
    if (!canonical_payload) {
      blocked_remote_keys_.insert(record.key);
      continue;
    }
    std::string fingerprint = ContentFingerprint(*canonical_payload);

    if (existing != local_by_key.end()) {
      std::optional<std::string> local_payload =
          PasswordPayloadJSON(*existing->second);
      if (local_payload && ContentFingerprint(*local_payload) ==
                               ContentFingerprint(*canonical_payload)) {
        credential_state_[record.key] = {fingerprint, record.seq,
                                         record.revision, false, record.key_id};
        continue;
      }
    }

    RemotePasswordRecord expected = remote;
    expected.fingerprint = fingerprint;
    pending_verification_[record.key] = std::move(expected);
    pending_remote_writes_++;
    if (existing == local_by_key.end()) {
      profile_store_->AddLogin(
          *credential,
          base::BindOnce(&HeliumPasswordSyncBridge::OnRemoteRecordComplete,
                         weak_factory_.GetWeakPtr()));
    } else {
      profile_store_->UpdateLogin(
          *credential,
          base::BindOnce(&HeliumPasswordSyncBridge::OnRemoteRecordComplete,
                         weak_factory_.GetWeakPtr()));
    }
    known_keys_.insert(record.key);
  }
  pending_remote_records_.clear();
  if (!blocked_remote_keys_.empty()) {
    applying_remote_ = false;
    reconciling_ = false;
    LOG(WARNING) << "Helium password sync left the verified cursor unchanged "
                    "because remote records are blocked";
    AndroidStatusLog("password reconciliation blocked; cursor unchanged");
    return;
  }
  if (pending_remote_writes_ == 0) {
    applying_remote_ = false;
    RequestPostApplyRead();
  }
}

bool HeliumPasswordSyncBridge::VerifyRemoteWrites(
    const password_manager::LoginsResult &local_credentials) {
  std::map<std::string, const Credential *> local_by_key;
  for (const auto &credential : local_credentials) {
    local_by_key[PasswordRecordKey(credential)] = &credential;
  }
  for (const auto &[key, expected] : pending_verification_) {
    const Record &record = expected.record;
    const auto local = local_by_key.find(key);
    if (record.deleted) {
      if (local != local_by_key.end()) {
        return false;
      }
    } else {
      if (local == local_by_key.end()) {
        return false;
      }
      std::optional<std::string> payload = PasswordPayloadJSON(*local->second);
      if (!payload || ContentFingerprint(*payload) != expected.fingerprint) {
        return false;
      }
    }
    credential_state_[key] = {expected.fingerprint, record.seq, record.revision,
                              record.deleted, record.key_id};
  }
  pending_verification_.clear();
  return SaveState();
}

void HeliumPasswordSyncBridge::PublishLocalMutations(
    const password_manager::LoginsResult &credentials) {
  known_keys_ = KeysFor(credentials);
  std::vector<Record> records;
  for (const auto &credential : credentials) {
    std::optional<Record> record = UpsertRecordForCredential(credential);
    if (!record || blocked_remote_keys_.contains(record->key)) {
      continue;
    }
    std::string fingerprint = ContentFingerprint(record->payload_json);
    const auto state = credential_state_.find(record->key);
    if (client_->enrollment_phase() == "pending" &&
        state == credential_state_.end()) {
      credential_state_[record->key] = {std::move(fingerprint), 0, 0, false,
                                        std::string()};
      continue;
    }
    if (!state_trusted_ && state == credential_state_.end()) {
      credential_state_[record->key] = {std::move(fingerprint), 0};
      continue;
    }
    if (state != credential_state_.end() &&
        state->second.fingerprint == fingerprint) {
      continue;
    }
    records.push_back(std::move(*record));
  }
  PushRecords(std::move(records));
}

void HeliumPasswordSyncBridge::PushRecords(std::vector<Record> records) {
  if (records.empty() || !client_) {
    return;
  }
  LOG(WARNING) << "Helium password sync pushing " << records.size()
               << " records as " << device_name_;
  AndroidStatusLog("password pushing count=" +
                   base::NumberToString(records.size()));
  std::map<std::string, std::string> fingerprints;
  for (auto &record : records) {
    const auto state = credential_state_.find(record.key);
    record.expected_revision =
        state == credential_state_.end() ? 0 : state->second.revision;
    fingerprints[record.key] = ContentFingerprint(record.payload_json);
  }
  client_->Push(std::move(records),
                base::BindOnce(&HeliumPasswordSyncBridge::OnPushComplete,
                               weak_factory_.GetWeakPtr(),
                               std::move(fingerprints)));
}

void HeliumPasswordSyncBridge::OnPushComplete(
    std::map<std::string, std::string> fingerprints, bool ok,
    RecordsResult result, std::string error) {
  if (!ok) {
    LOG(WARNING) << "Helium password sync push failed: " << error;
    AndroidStatusLog("password push failed " + error);
    return;
  }
  if (result.records.size() != fingerprints.size()) {
    LOG(WARNING) << "Helium password sync push returned wrong record count";
    return;
  }
  for (const Record &accepted : result.records) {
    const auto fingerprint = fingerprints.find(accepted.key);
    if (fingerprint == fingerprints.end()) {
      LOG(WARNING) << "Helium password sync push returned an unknown record";
      return;
    }
    credential_state_[accepted.key] = {
        accepted.deleted ? std::string() : fingerprint->second, accepted.seq,
        accepted.revision, accepted.deleted, accepted.key_id};
  }
  SaveState();
  LOG(WARNING) << "Helium password sync push completed";
  AndroidStatusLog("password push completed");
}

void HeliumPasswordSyncBridge::OnPullComplete(bool ok, RecordsResult result,
                                              std::string error) {
  pull_in_flight_ = false;
  if (!ok) {
    LOG(WARNING) << "Helium password sync pull failed: " << error;
    AndroidStatusLog("password pull failed " + error);
    reconciling_ = false;
    return;
  }
  pending_next_seq_ = result.next_seq;

  pending_remote_records_.clear();
  blocked_remote_keys_.clear();
  for (Record &record : result.records) {
    if (record.kind != kPasswordKind) {
      continue;
    }
    RemotePasswordRecord remote;
    remote.record = std::move(record);
    if (!remote.record.deleted) {
      std::optional<base::Value> payload = base::JSONReader::Read(
          remote.record.payload_json, base::JSON_PARSE_RFC);
      if (!payload || !payload->is_dict() ||
          !PayloadToCredential(payload->GetDict())) {
        blocked_remote_keys_.insert(remote.record.key);
        continue;
      }
    }
    pending_remote_records_.push_back(std::move(remote));
  }

  if (pending_remote_records_.empty()) {
    LOG(WARNING) << "Helium password sync pull found no password records";
    AndroidStatusLog("password pull empty");
    RequestReconcileRead();
    return;
  }
  LOG(WARNING) << "Helium password sync pulled "
               << pending_remote_records_.size() << " password records";
  AndroidStatusLog("password pulled count=" +
                   base::NumberToString(pending_remote_records_.size()));
  RequestReconcileRead();
}

void HeliumPasswordSyncBridge::OnRemoteRecordComplete() {
  if (pending_remote_writes_ > 0) {
    pending_remote_writes_--;
  }
  if (pending_remote_writes_ > 0) {
    return;
  }
  applying_remote_ = false;
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&HeliumPasswordSyncBridge::RequestPostApplyRead,
                     weak_factory_.GetWeakPtr()),
      base::Seconds(2));
}

void HeliumPasswordSyncBridge::FinishReconcile() {
  state_trusted_ = true;
  verified_sequence_ = pending_next_seq_;
  if (!SaveState()) {
    LOG(WARNING) << "Helium password sync could not persist verified state";
    reconciling_ = false;
    return;
  }
  std::string error;
  if (!client_->AcknowledgeApplied(pending_next_seq_, &error)) {
    LOG(WARNING) << "Helium password sync cursor acknowledgement failed: "
                 << error;
    reconciling_ = false;
    return;
  }
  reconciling_ = false;
  if (!observing_ && profile_store_) {
    observing_ = true;
    profile_store_->AddObserver(this);
  }
  if (!pull_timer_.IsRunning()) {
    pull_timer_.Start(
        FROM_HERE, base::Seconds(30),
        base::BindRepeating(&HeliumPasswordSyncBridge::PullAndApply,
                            weak_factory_.GetWeakPtr()));
  }
}

bool HeliumPasswordSyncBridge::LoadState() {
  credential_state_.clear();
  if (state_path_.empty() || !base::PathExists(state_path_)) {
    return false;
  }

  std::string raw;
  if (!base::ReadFileToString(state_path_, &raw)) {
    LOG(WARNING) << "Helium password sync could not read state";
    return false;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("schema_version").value_or(0) !=
          kPasswordStateSchema) {
    LOG(WARNING) << "Helium password sync state is invalid";
    return false;
  }
  const base::DictValue *credentials =
      parsed->GetDict().FindDict("credentials");
  const std::string *verified_sequence =
      parsed->GetDict().FindString("verified_sequence");
  if (!credentials || !verified_sequence ||
      !base::StringToInt64(*verified_sequence, &verified_sequence_) ||
      verified_sequence_ < 0) {
    LOG(WARNING) << "Helium password sync state has no credentials map";
    return false;
  }
  for (const auto [key, value] : *credentials) {
    if (!value.is_dict()) {
      return false;
    }
    const std::string *fingerprint = value.GetDict().FindString("fingerprint");
    const std::string *remote_seq = value.GetDict().FindString("remote_seq");
    const std::string *revision = value.GetDict().FindString("revision");
    const std::string *key_id = value.GetDict().FindString("key_id");
    std::optional<bool> deleted = value.GetDict().FindBool("deleted");
    int64_t parsed_seq = 0;
    int64_t parsed_revision = 0;
    if (!fingerprint || !remote_seq || !revision || !key_id || !deleted ||
        (!*deleted && fingerprint->empty()) ||
        !base::StringToInt64(*remote_seq, &parsed_seq) || parsed_seq < 0 ||
        !base::StringToInt64(*revision, &parsed_revision) ||
        parsed_revision < 0 || (parsed_revision > 0 && key_id->empty())) {
      credential_state_.clear();
      return false;
    }
    credential_state_[key] = {*fingerprint, parsed_seq, parsed_revision,
                              *deleted, *key_id};
  }
  return true;
}

bool HeliumPasswordSyncBridge::SaveState() const {
  if (state_path_.empty() || !base::CreateDirectory(state_path_.DirName())) {
    LOG(WARNING) << "Helium password sync could not create state directory";
    return false;
  }
  base::DictValue root;
  root.Set("schema_version", kPasswordStateSchema);
  root.Set("verified_sequence", base::NumberToString(verified_sequence_));
  base::DictValue credentials;
  for (const auto &[key, state] : credential_state_) {
    base::DictValue value;
    value.Set("fingerprint", state.fingerprint);
    value.Set("remote_seq", base::NumberToString(state.remote_seq));
    value.Set("revision", base::NumberToString(state.revision));
    value.Set("deleted", state.deleted);
    value.Set("key_id", state.key_id);
    credentials.Set(key, std::move(value));
  }
  root.Set("credentials", std::move(credentials));
  std::string raw;
  if (!base::JSONWriter::Write(root, &raw)) {
    return false;
  }
  return base::ImportantFileWriter::WriteFileAtomically(state_path_, raw,
                                                        "HeliumSync");
}

std::set<std::string> HeliumPasswordSyncBridge::KeysFor(
    const password_manager::LoginsResult &credentials) const {
  std::set<std::string> keys;
  for (const auto &credential : credentials) {
    keys.insert(PasswordRecordKey(credential));
  }
  return keys;
}

} // namespace helium_sync
