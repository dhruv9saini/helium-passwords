// Copyright 2026 The Helium Authors

#include "components/helium_sync/helium_password_sync_bridge.h"

#include <algorithm>
#include <limits>
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
#include "base/numerics/safe_conversions.h"
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
constexpr char kPasswordIdentitySchema[] = "password-form-unique-key-v2";
constexpr char kPasswordIdentityPrefix[] = "credential/v2/";
constexpr char kLegacyPasswordIdentityPrefix[] = "credential/";
constexpr char kDeletedFingerprint[] = "deleted";
constexpr int kPasswordStateSchema = 4;
constexpr int kLegacyPasswordStateSchema = 3;

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

void AppendU32(uint32_t value, std::string *out) {
  out->push_back(static_cast<char>((value >> 24) & 0xff));
  out->push_back(static_cast<char>((value >> 16) & 0xff));
  out->push_back(static_cast<char>((value >> 8) & 0xff));
  out->push_back(static_cast<char>(value & 0xff));
}

void AppendStringField(std::string_view value, std::string *out) {
  AppendU32(base::checked_cast<uint32_t>(value.size()), out);
  out->append(value);
}

void AppendUTF16Field(std::u16string_view value, std::string *out) {
  AppendU32(base::checked_cast<uint32_t>(value.size()), out);
  for (char16_t code_unit : value) {
    out->push_back(static_cast<char>((code_unit >> 8) & 0xff));
    out->push_back(static_cast<char>(code_unit & 0xff));
  }
}

std::string LegacyPasswordRecordKeyForValues(std::string_view signon_realm,
                                             std::string_view url,
                                             const std::u16string &username) {
  std::string material;
  material.append(signon_realm);
  material.push_back('\0');
  material.append(url);
  material.push_back('\0');
  material.append(base::UTF16ToUTF8(username));
  return std::string(kLegacyPasswordIdentityPrefix) +
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

std::string PasswordIdentityMaterial(const Credential &credential) {
  std::string material("helium-password-identity-v2\0", 28);
  AppendStringField(credential.url.spec(), &material);
  AppendUTF16Field(credential.username_element, &material);
  AppendUTF16Field(credential.username_value, &material);
  AppendUTF16Field(credential.password_element, &material);
  AppendStringField(credential.signon_realm, &material);
  return material;
}

std::string PasswordRecordKey(const Credential &credential) {
  return std::string(kPasswordIdentityPrefix) +
         base::HexEncodeLower(
             crypto::SHA256HashString(PasswordIdentityMaterial(credential)));
}

std::string LegacyPasswordRecordKey(const Credential &credential) {
  return LegacyPasswordRecordKeyForValues(SignonRealmForCredential(credential),
                                          UrlForCredential(credential),
                                          credential.username_value);
}

std::string
PasswordRecordKeyForForm(const password_manager::PasswordForm &credential) {
  return PasswordRecordKey(credential);
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
    base::FilePath state_path,
    base::RepeatingCallback<void(int64_t)> verified_baseline_callback)
    : profile_store_(std::move(profile_store)), client_(std::move(client)),
      device_name_(std::move(device_name)), state_path_(std::move(state_path)),
      verified_baseline_callback_(std::move(verified_baseline_callback)) {}

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
  if (!legacy_credential_state_.empty() && !SaveState()) {
    LOG(WARNING) << "Helium password sync could not persist the schema-3 "
                    "identity migration";
    AndroidStatusLog("password identity migration write failed");
    return;
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
  if (!profile_store_ || !client_ || pull_in_flight_ || reconciling_ ||
      push_in_flight_) {
    return;
  }
  pull_in_flight_ = true;
  reconciling_ = true;
  client_->Latest({kPasswordKind},
                  base::BindOnce(&HeliumPasswordSyncBridge::OnPullComplete,
                                 weak_factory_.GetWeakPtr()));
}

bool HeliumPasswordSyncBridge::EnrollmentActivated(std::string *error) {
  if (!client_ || !client_->ReloadEnrollmentState(error)) {
    return false;
  }
  if (client_->enrollment_phase() != "active") {
    if (error) {
      *error = "password client enrollment is not active";
    }
    return false;
  }
  verified_baseline_callback_.Reset();
  return true;
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

void HeliumPasswordSyncBridge::RequestPublicationRead() {
  if (!profile_store_ || pending_read_ != PendingRead::kNone) {
    return;
  }
  pending_read_ = PendingRead::kPublishLocal;
  profile_store_->GetAllLogins(weak_factory_.GetWeakPtr());
}

void HeliumPasswordSyncBridge::OnLoginsChanged(
    password_manager::PasswordStoreInterface *store,
    const password_manager::PasswordStoreChangeList &changes) {
  if (store != profile_store_.get() || applying_remote_) {
    return;
  }
  QueueLocalMutations(changes);
}

void HeliumPasswordSyncBridge::OnLoginsRetained(
    password_manager::PasswordStoreInterface *store,
    const std::vector<password_manager::PasswordForm> &retained_passwords) {
  if (store != profile_store_.get() || applying_remote_) {
    return;
  }

  std::set<std::string> retained_keys;
  for (const auto &credential : retained_passwords) {
    retained_keys.insert(PasswordRecordKeyForForm(credential));
  }
  for (const std::string &key : known_keys_) {
    if (retained_keys.contains(key)) {
      continue;
    }
    const auto state = credential_state_.find(key);
    if (state != credential_state_.end()) {
      state->second.queued_mutation = QueuedMutation{kDeletedFingerprint, true};
    }
  }
  known_keys_ = std::move(retained_keys);
  if (!SaveState()) {
    state_trusted_ = false;
    return;
  }
  MaybeStartPublication();
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
    if (pending != PendingRead::kPublishLocal) {
      reconciling_ = false;
    }
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
  case PendingRead::kPublishLocal:
    PublishQueuedMutation(*credentials);
    break;
  }
}

bool HeliumPasswordSyncBridge::MigrateLegacyIdentity(
    const password_manager::LoginsResult &credentials) {
  if (legacy_credential_state_.empty()) {
    return true;
  }
  std::map<std::string, std::vector<const Credential *>> local_by_legacy_key;
  for (const auto &credential : credentials) {
    local_by_legacy_key[LegacyPasswordRecordKey(credential)].push_back(
        &credential);
  }
  bool changed = false;
  for (const auto &[legacy_key, legacy_state] : legacy_credential_state_) {
    const auto candidates = local_by_legacy_key.find(legacy_key);
    const size_t count =
        candidates == local_by_legacy_key.end() ? 0 : candidates->second.size();
    if (count > 1) {
      LOG(WARNING) << "Helium password schema-3 identity collision for "
                   << legacy_key;
      AndroidStatusLog("password legacy identity collision; fail closed");
      return false;
    }
    if (count == 0) {
      if (!legacy_state.deleted) {
        LOG(WARNING) << "Helium password live schema-3 state has no unique "
                        "local identity";
        return false;
      }
      continue;
    }
    const Credential &credential = *candidates->second.front();
    const std::string canonical_key = PasswordRecordKey(credential);
    std::optional<std::string> payload = PasswordPayloadJSON(credential);
    if (!payload) {
      return false;
    }
    const std::string fingerprint = ContentFingerprint(*payload);
    if (legacy_state.deleted || legacy_state.fingerprint != fingerprint) {
      LOG(WARNING) << "Helium password schema-3 state does not match its "
                      "unique local credential";
      return false;
    }
    const auto existing = credential_state_.find(canonical_key);
    const auto remote = std::find_if(
        pending_remote_records_.begin(), pending_remote_records_.end(),
        [&canonical_key](const RemotePasswordRecord &candidate) {
          return candidate.record.key == canonical_key;
        });
    if (existing != credential_state_.end() &&
        (existing->second.revision > 0 ||
         existing->second.pending_publication)) {
      continue;
    }
    const bool migration_queued =
        existing != credential_state_.end() && existing->second.deleted &&
        existing->second.revision == 0 && existing->second.queued_mutation &&
        !existing->second.queued_mutation->deleted &&
        existing->second.queued_mutation->credential_fingerprint == fingerprint;
    if (remote != pending_remote_records_.end() &&
        (existing == credential_state_.end() || migration_queued)) {
      if (remote->record.deleted || remote->fingerprint != fingerprint) {
        LOG(WARNING) << "Helium password canonical remote conflicts with "
                        "schema-3 migration source";
        return false;
      }
      credential_state_[canonical_key] = {fingerprint, remote->record.seq,
                                          remote->record.revision, false,
                                          remote->record.key_id};
      changed = true;
      continue;
    }
    if (existing != credential_state_.end()) {
      if (!migration_queued && (existing->second.deleted ||
                                existing->second.fingerprint != fingerprint)) {
        LOG(WARNING) << "Helium password migration would collapse distinct "
                        "canonical state";
        return false;
      }
      continue;
    }
    CredentialState migrated{std::string(), legacy_state.remote_seq, 0, true,
                             std::string()};
    if (client_->enrollment_phase() == "active") {
      migrated.queued_mutation = QueuedMutation{fingerprint, false};
    }
    credential_state_.emplace(canonical_key, std::move(migrated));
    changed = true;
  }
  return !changed || SaveState();
}

bool HeliumPasswordSyncBridge::ResolvePendingPublications() {
  std::map<std::string, const RemotePasswordRecord *> remote_by_key;
  for (const auto &remote : pending_remote_records_) {
    if (!remote_by_key.emplace(remote.record.key, &remote).second) {
      LOG(WARNING) << "Helium password pull returned duplicate record keys";
      return false;
    }
  }
  bool changed = false;
  for (auto &[key, state] : credential_state_) {
    if (!state.pending_publication) {
      continue;
    }
    const PendingPublication pending = *state.pending_publication;
    const auto found = remote_by_key.find(key);
    if (found != remote_by_key.end() &&
        found->second->record.revision == pending.target_revision &&
        found->second->record.deleted == pending.deleted &&
        found->second->fingerprint == pending.payload_fingerprint) {
      const Record &accepted = found->second->record;
      state.fingerprint =
          pending.deleted ? std::string() : pending.credential_fingerprint;
      state.remote_seq = accepted.seq;
      state.revision = accepted.revision;
      state.deleted = accepted.deleted;
      state.key_id = accepted.key_id;
      state.pending_publication.reset();
      changed = true;
      continue;
    }

    const bool absent_at_zero =
        found == remote_by_key.end() && pending.expected_revision == 0;
    bool unchanged_baseline = false;
    if (found != remote_by_key.end() &&
        found->second->record.revision == pending.expected_revision &&
        found->second->record.deleted == state.deleted) {
      unchanged_baseline =
          state.deleted ? found->second->fingerprint == kDeletedFingerprint
                        : found->second->fingerprint == state.fingerprint;
    }
    if (!absent_at_zero && !unchanged_baseline) {
      LOG(WARNING) << "Helium password pending publication met a stale remote "
                      "revision for "
                   << key;
      return false;
    }
    if (!state.queued_mutation) {
      state.queued_mutation =
          QueuedMutation{pending.credential_fingerprint, pending.deleted};
    }
    state.pending_publication.reset();
    changed = true;
  }
  return !changed || SaveState();
}

void HeliumPasswordSyncBridge::ReconcileRemotePasswords(
    const password_manager::LoginsResult &local_credentials) {
  if (!ResolvePendingPublications() ||
      !MigrateLegacyIdentity(local_credentials)) {
    pending_remote_records_.clear();
    reconciling_ = false;
    state_trusted_ = false;
    LOG(WARNING) << "Helium password identity/publication migration blocked";
    return;
  }
  std::map<std::string, const Credential *> local_by_key;
  std::map<std::string, std::string> material_by_key;
  for (const auto &credential : local_credentials) {
    const std::string key = PasswordRecordKey(credential);
    const std::string material = PasswordIdentityMaterial(credential);
    const auto found = material_by_key.find(key);
    if (found != material_by_key.end() && found->second != material) {
      pending_remote_records_.clear();
      reconciling_ = false;
      state_trusted_ = false;
      LOG(WARNING) << "Helium password local identity collision";
      return;
    }
    material_by_key[key] = material;
    local_by_key[key] = &credential;
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
          parsed && parsed->is_dict() ? PayloadToCredential(parsed->GetDict())
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
  std::map<std::string, const Credential *> local_by_key;
  std::map<std::string, std::string> identity_material_by_key;
  for (const auto &credential : credentials) {
    std::optional<Record> record = UpsertRecordForCredential(credential);
    if (!record || blocked_remote_keys_.contains(record->key)) {
      continue;
    }
    std::string material = PasswordIdentityMaterial(credential);
    const auto material_it = identity_material_by_key.find(record->key);
    if (material_it != identity_material_by_key.end() &&
        material_it->second != material) {
      LOG(WARNING) << "Helium password identity hash collision; fail closed";
      state_trusted_ = false;
      return;
    }
    identity_material_by_key[record->key] = std::move(material);
    local_by_key[record->key] = &credential;
    std::string fingerprint = ContentFingerprint(record->payload_json);
    if (client_->enrollment_phase() == "pending" &&
        !credential_state_.contains(record->key)) {
      credential_state_[record->key] = {std::move(fingerprint), 0, 0, false,
                                        std::string()};
      continue;
    }
    auto [state, inserted] = credential_state_.try_emplace(
        record->key, CredentialState{std::string(), 0, 0, true, std::string()});
    if (!state_trusted_ && inserted) {
      state->second.fingerprint = std::move(fingerprint);
      state->second.deleted = false;
      continue;
    }
    QueuedMutation desired{fingerprint, false};
    if (state->second.pending_publication) {
      const PendingPublication &pending = *state->second.pending_publication;
      if (pending.deleted || pending.credential_fingerprint != fingerprint) {
        state->second.queued_mutation = std::move(desired);
      } else {
        state->second.queued_mutation.reset();
      }
    } else if (!state->second.deleted &&
               state->second.fingerprint == fingerprint) {
      state->second.queued_mutation.reset();
    } else {
      state->second.queued_mutation = std::move(desired);
    }
  }

  if (client_->enrollment_phase() != "pending") {
    for (auto &[key, state] : credential_state_) {
      if (local_by_key.contains(key)) {
        continue;
      }
      QueuedMutation desired{kDeletedFingerprint, true};
      if (state.pending_publication) {
        if (!state.pending_publication->deleted) {
          state.queued_mutation = std::move(desired);
        } else {
          state.queued_mutation.reset();
        }
      } else if (state.deleted) {
        state.queued_mutation.reset();
      } else {
        state.queued_mutation = std::move(desired);
      }
    }
  }
  if (!SaveState()) {
    LOG(WARNING) << "Helium password sync could not persist queued mutations";
    state_trusted_ = false;
  }
}

void HeliumPasswordSyncBridge::QueueLocalMutations(
    const password_manager::PasswordStoreChangeList &changes) {
  std::map<std::string, std::string> material_by_key;
  for (const auto &change : changes) {
    const Credential &credential = ChangeCredential(change);
    const std::string key = PasswordRecordKey(credential);
    const std::string material = PasswordIdentityMaterial(credential);
    const auto material_it = material_by_key.find(key);
    if (material_it != material_by_key.end() &&
        material_it->second != material) {
      LOG(WARNING)
          << "Helium password observer identity collision; fail closed";
      state_trusted_ = false;
      return;
    }
    material_by_key[key] = material;
    auto state = credential_state_
                     .try_emplace(key, CredentialState{std::string(), 0, 0,
                                                       true, std::string()})
                     .first;
    QueuedMutation mutation;
    if (change.type() == password_manager::PasswordStoreChange::REMOVE) {
      mutation = {kDeletedFingerprint, true};
      known_keys_.erase(key);
    } else {
      std::optional<Record> record = UpsertRecordForCredential(credential);
      if (!record) {
        state_trusted_ = false;
        return;
      }
      mutation = {ContentFingerprint(record->payload_json), false};
      known_keys_.insert(key);
    }
    state->second.queued_mutation = std::move(mutation);
  }
  if (!SaveState()) {
    LOG(WARNING) << "Helium password sync could not persist observer mutations";
    state_trusted_ = false;
    return;
  }
  MaybeStartPublication();
}

void HeliumPasswordSyncBridge::MaybeStartPublication() {
  if (!profile_store_ || !client_ || !state_trusted_ || reconciling_ ||
      applying_remote_ || push_in_flight_ ||
      pending_read_ != PendingRead::kNone ||
      client_->enrollment_phase() != "active") {
    return;
  }
  for (const auto &[key, state] : credential_state_) {
    if (state.pending_publication) {
      PullAndApply();
      return;
    }
  }
  for (const auto &[key, state] : credential_state_) {
    if (state.queued_mutation) {
      RequestPublicationRead();
      return;
    }
  }
}

void HeliumPasswordSyncBridge::PublishQueuedMutation(
    const password_manager::LoginsResult &credentials) {
  std::map<std::string, const Credential *> local_by_key;
  std::map<std::string, std::string> material_by_key;
  for (const auto &credential : credentials) {
    const std::string key = PasswordRecordKey(credential);
    const std::string material = PasswordIdentityMaterial(credential);
    const auto found = material_by_key.find(key);
    if (found != material_by_key.end() && found->second != material) {
      LOG(WARNING) << "Helium password publication identity collision";
      state_trusted_ = false;
      return;
    }
    material_by_key[key] = material;
    local_by_key[key] = &credential;
  }

  auto state = std::find_if(credential_state_.begin(), credential_state_.end(),
                            [](const auto &entry) {
                              return entry.second.queued_mutation.has_value();
                            });
  if (state == credential_state_.end()) {
    return;
  }
  const std::string key = state->first;
  Record mutation;
  mutation.kind = kPasswordKind;
  mutation.key = key;
  std::string fingerprint = kDeletedFingerprint;
  bool deleted = true;
  const auto local = local_by_key.find(key);
  if (local != local_by_key.end()) {
    std::optional<Record> upsert = UpsertRecordForCredential(*local->second);
    if (!upsert) {
      state_trusted_ = false;
      return;
    }
    mutation = std::move(*upsert);
    fingerprint = ContentFingerprint(mutation.payload_json);
    deleted = false;
  } else {
    mutation.deleted = true;
    mutation.payload_json = "{}";
  }

  state->second.queued_mutation = QueuedMutation{fingerprint, deleted};
  const bool matches_baseline =
      state->second.deleted == deleted &&
      (deleted || state->second.fingerprint == fingerprint);
  if (matches_baseline) {
    state->second.queued_mutation.reset();
    if (!SaveState()) {
      state_trusted_ = false;
      return;
    }
    MaybeStartPublication();
    return;
  }

  mutation.expected_revision = state->second.revision;
  state->second.pending_publication = PendingPublication{
      mutation.expected_revision, mutation.expected_revision + 1,
      deleted ? kDeletedFingerprint : ContentFingerprint(mutation.payload_json),
      fingerprint, deleted};
  state->second.queued_mutation.reset();
  if (!SaveState()) {
    LOG(WARNING) << "Helium password pending publication write failed";
    state_trusted_ = false;
    return;
  }
  push_in_flight_ = true;
  std::vector<Record> records;
  records.push_back(std::move(mutation));
  client_->Push(std::move(records),
                base::BindOnce(&HeliumPasswordSyncBridge::OnPushComplete,
                               weak_factory_.GetWeakPtr()));
}

void HeliumPasswordSyncBridge::OnPushComplete(bool ok, RecordsResult,
                                              std::string error) {
  push_in_flight_ = false;
  LOG(WARNING) << "Helium password push requires pull verification: ok=" << ok
               << " detail=" << error;
  AndroidStatusLog("password push pending pull verification");
  PullAndApply();
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
  std::vector<RemotePasswordRecord> legacy_live_records;
  for (Record &record : result.records) {
    if (record.kind != kPasswordKind) {
      continue;
    }
    RemotePasswordRecord remote;
    remote.record = std::move(record);
    if (!remote.record.deleted) {
      std::optional<base::Value> payload = base::JSONReader::Read(
          remote.record.payload_json, base::JSON_PARSE_RFC);
      std::optional<Credential> credential =
          payload && payload->is_dict()
              ? PayloadToCredential(payload->GetDict())
              : std::nullopt;
      if (!credential) {
        blocked_remote_keys_.insert(remote.record.key);
        continue;
      }
      remote.fingerprint = ContentFingerprint(remote.record.payload_json);
      if (remote.record.key.starts_with(kPasswordIdentityPrefix)) {
        if (PasswordRecordKey(*credential) != remote.record.key) {
          blocked_remote_keys_.insert(remote.record.key);
          continue;
        }
      } else if (remote.record.key.starts_with(kLegacyPasswordIdentityPrefix) &&
                 LegacyPasswordRecordKey(*credential) == remote.record.key) {
        legacy_live_records.push_back(std::move(remote));
        continue;
      } else {
        blocked_remote_keys_.insert(remote.record.key);
        continue;
      }
    } else {
      remote.fingerprint = kDeletedFingerprint;
      if (remote.record.key.starts_with(kLegacyPasswordIdentityPrefix) &&
          !remote.record.key.starts_with(kPasswordIdentityPrefix)) {
        continue;
      }
      if (!remote.record.key.starts_with(kPasswordIdentityPrefix)) {
        blocked_remote_keys_.insert(remote.record.key);
        continue;
      }
    }
    pending_remote_records_.push_back(std::move(remote));
  }

  std::set<std::string> canonical_remote_keys;
  for (const auto &remote : pending_remote_records_) {
    canonical_remote_keys.insert(remote.record.key);
  }
  for (const auto &legacy : legacy_live_records) {
    std::optional<base::Value> payload = base::JSONReader::Read(
        legacy.record.payload_json, base::JSON_PARSE_RFC);
    std::optional<Credential> credential =
        payload && payload->is_dict() ? PayloadToCredential(payload->GetDict())
                                      : std::nullopt;
    const std::string canonical_key =
        credential ? PasswordRecordKey(*credential) : std::string();
    const auto legacy_state = legacy_credential_state_.find(legacy.record.key);
    const bool preserved_migration_source =
        legacy_state != legacy_credential_state_.end() &&
        !legacy_state->second.deleted &&
        legacy_state->second.fingerprint == legacy.fingerprint;
    if (!canonical_remote_keys.contains(canonical_key) &&
        !preserved_migration_source) {
      blocked_remote_keys_.insert(legacy.record.key);
    }
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
  if (client_->enrollment_phase() == "pending" && verified_baseline_callback_) {
    verified_baseline_callback_.Run(verified_sequence_);
  }
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
  MaybeStartPublication();
}

bool HeliumPasswordSyncBridge::LoadState() {
  credential_state_.clear();
  legacy_credential_state_.clear();
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
  if (!parsed || !parsed->is_dict()) {
    LOG(WARNING) << "Helium password sync state is invalid";
    return false;
  }
  const base::DictValue &root = parsed->GetDict();
  const int schema = root.FindInt("schema_version").value_or(0);
  const base::DictValue *credentials = root.FindDict("credentials");
  const std::string *verified_sequence = root.FindString("verified_sequence");
  if (!credentials || !verified_sequence ||
      !base::StringToInt64(*verified_sequence, &verified_sequence_) ||
      verified_sequence_ < 0) {
    LOG(WARNING) << "Helium password sync state has no credentials map";
    return false;
  }
  int pending_count = 0;
  auto parse_state_map = [&pending_count](
                             const base::DictValue &values,
                             std::map<std::string, CredentialState> *out,
                             bool allow_publication_state) {
    for (const auto [key, value] : values) {
      if (!value.is_dict()) {
        return false;
      }
      const base::DictValue &entry = value.GetDict();
      const std::string *fingerprint = entry.FindString("fingerprint");
      const std::string *remote_seq = entry.FindString("remote_seq");
      const std::string *revision = entry.FindString("revision");
      const std::string *key_id = entry.FindString("key_id");
      std::optional<bool> deleted = entry.FindBool("deleted");
      int64_t parsed_seq = 0;
      int64_t parsed_revision = 0;
      if (!fingerprint || !remote_seq || !revision || !key_id || !deleted ||
          (*deleted ? !fingerprint->empty() : fingerprint->empty()) ||
          !base::StringToInt64(*remote_seq, &parsed_seq) || parsed_seq < 0 ||
          !base::StringToInt64(*revision, &parsed_revision) ||
          parsed_revision < 0 || (parsed_revision > 0 && key_id->empty())) {
        return false;
      }
      CredentialState state{*fingerprint, parsed_seq, parsed_revision, *deleted,
                            *key_id};
      if (const base::DictValue *pending =
              entry.FindDict("pending_publication")) {
        if (!allow_publication_state) {
          return false;
        }
        const std::string *expected = pending->FindString("expected_revision");
        const std::string *target = pending->FindString("target_revision");
        const std::string *payload = pending->FindString("payload_fingerprint");
        const std::string *credential =
            pending->FindString("credential_fingerprint");
        std::optional<bool> pending_deleted = pending->FindBool("deleted");
        int64_t expected_revision = 0;
        int64_t target_revision = 0;
        if (!expected || !target || !payload || payload->empty() ||
            !credential || credential->empty() || !pending_deleted ||
            !base::StringToInt64(*expected, &expected_revision) ||
            !base::StringToInt64(*target, &target_revision) ||
            expected_revision < 0 ||
            expected_revision == std::numeric_limits<int64_t>::max() ||
            target_revision != expected_revision + 1 ||
            expected_revision != parsed_revision) {
          return false;
        }
        state.pending_publication =
            PendingPublication{expected_revision, target_revision, *payload,
                               *credential, *pending_deleted};
        pending_count++;
      }
      if (const base::DictValue *queued = entry.FindDict("queued_mutation")) {
        if (!allow_publication_state) {
          return false;
        }
        const std::string *queued_fingerprint =
            queued->FindString("credential_fingerprint");
        std::optional<bool> queued_deleted = queued->FindBool("deleted");
        if (!queued_fingerprint || queued_fingerprint->empty() ||
            !queued_deleted) {
          return false;
        }
        state.queued_mutation =
            QueuedMutation{*queued_fingerprint, *queued_deleted};
      }
      out->emplace(key, std::move(state));
    }
    return true;
  };

  if (schema == kLegacyPasswordStateSchema) {
    if (!parse_state_map(*credentials, &legacy_credential_state_, false)) {
      legacy_credential_state_.clear();
      return false;
    }
    for (const auto &[key, state] : legacy_credential_state_) {
      if (!key.starts_with(kLegacyPasswordIdentityPrefix) ||
          key.starts_with(kPasswordIdentityPrefix)) {
        legacy_credential_state_.clear();
        return false;
      }
    }
    return true;
  }
  const std::string *identity_schema = root.FindString("identity_schema");
  const base::DictValue *legacy = root.FindDict("legacy_credentials");
  if (schema != kPasswordStateSchema || !identity_schema ||
      *identity_schema != kPasswordIdentitySchema || !legacy ||
      !parse_state_map(*credentials, &credential_state_, true) ||
      !parse_state_map(*legacy, &legacy_credential_state_, false) ||
      pending_count > 1) {
    credential_state_.clear();
    legacy_credential_state_.clear();
    return false;
  }
  for (const auto &[key, state] : credential_state_) {
    if (!key.starts_with(kPasswordIdentityPrefix)) {
      return false;
    }
  }
  for (const auto &[key, state] : legacy_credential_state_) {
    if (!key.starts_with(kLegacyPasswordIdentityPrefix) ||
        key.starts_with(kPasswordIdentityPrefix)) {
      return false;
    }
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
  root.Set("identity_schema", kPasswordIdentitySchema);
  root.Set("migration_status",
           legacy_credential_state_.empty() ? "complete" : "legacy-preserved");
  root.Set("verified_sequence", base::NumberToString(verified_sequence_));
  auto state_to_value = [](const CredentialState &state,
                           bool include_publication_state) {
    base::DictValue value;
    value.Set("fingerprint", state.fingerprint);
    value.Set("remote_seq", base::NumberToString(state.remote_seq));
    value.Set("revision", base::NumberToString(state.revision));
    value.Set("deleted", state.deleted);
    value.Set("key_id", state.key_id);
    if (include_publication_state && state.pending_publication) {
      base::DictValue pending;
      pending.Set(
          "expected_revision",
          base::NumberToString(state.pending_publication->expected_revision));
      pending.Set(
          "target_revision",
          base::NumberToString(state.pending_publication->target_revision));
      pending.Set("payload_fingerprint",
                  state.pending_publication->payload_fingerprint);
      pending.Set("credential_fingerprint",
                  state.pending_publication->credential_fingerprint);
      pending.Set("deleted", state.pending_publication->deleted);
      value.Set("pending_publication", std::move(pending));
    }
    if (include_publication_state && state.queued_mutation) {
      base::DictValue queued;
      queued.Set("credential_fingerprint",
                 state.queued_mutation->credential_fingerprint);
      queued.Set("deleted", state.queued_mutation->deleted);
      value.Set("queued_mutation", std::move(queued));
    }
    return value;
  };
  base::DictValue credentials;
  for (const auto &[key, state] : credential_state_) {
    credentials.Set(key, state_to_value(state, true));
  }
  root.Set("credentials", std::move(credentials));
  base::DictValue legacy;
  for (const auto &[key, state] : legacy_credential_state_) {
    legacy.Set(key, state_to_value(state, false));
  }
  root.Set("legacy_credentials", std::move(legacy));
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
