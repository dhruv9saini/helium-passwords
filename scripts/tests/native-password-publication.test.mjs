import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import test from "node:test";

const source = readFileSync(new URL(
  "../../chromium/overlay/components/helium_sync/helium_password_sync_bridge.cc",
  import.meta.url,
), "utf8");

function u32(value) {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value);
  return out;
}

function stringField(value) {
  const bytes = Buffer.from(value, "utf8");
  return Buffer.concat([u32(bytes.length), bytes]);
}

function utf16Field(value) {
  const bytes = Buffer.alloc(value.length * 2);
  for (let index = 0; index < value.length; index += 1) {
    bytes.writeUInt16BE(value.charCodeAt(index), index * 2);
  }
  return Buffer.concat([u32(value.length), bytes]);
}

function canonicalKey(form) {
  const material = Buffer.concat([
    Buffer.from("helium-password-identity-v2\0", "utf8"),
    stringField(form.url),
    utf16Field(form.usernameElement),
    utf16Field(form.usernameValue),
    utf16Field(form.passwordElement),
    stringField(form.signonRealm),
  ]);
  return `credential/v2/${createHash("sha256").update(material).digest("hex")}`;
}

function legacyKey(form) {
  const material = [form.signonRealm, form.url, form.usernameValue].join("\0");
  return `credential/${createHash("sha256").update(material).digest("hex")}`;
}

function migrateSchema3(legacyCredentials, localForms) {
  const groups = new Map();
  for (const form of localForms) {
    const key = legacyKey(form);
    groups.set(key, [...(groups.get(key) || []), form]);
  }
  const canonical = {};
  for (const [legacy, state] of Object.entries(legacyCredentials)) {
    const candidates = groups.get(legacy) || [];
    if (candidates.length > 1) throw new Error("legacy identity collision");
    if (candidates.length === 0) {
      if (!state.deleted) throw new Error("live legacy state has no identity");
      continue;
    }
    if (state.deleted || state.fingerprint !== candidates[0].fingerprint) {
      throw new Error("legacy state mismatch");
    }
    canonical[canonicalKey(candidates[0])] = {
      fingerprint: "",
      revision: 0,
      deleted: true,
      queued: {fingerprint: state.fingerprint, deleted: false},
    };
  }
  return {legacyCredentials: structuredClone(legacyCredentials), canonical};
}

class PublicationModel {
  constructor(state) {
    this.state = structuredClone(state);
  }

  observe(fingerprint, deleted = false) {
    this.state.queued = {fingerprint, deleted};
  }

  begin() {
    assert.equal(this.state.pending, undefined);
    const desired = this.state.queued;
    assert.ok(desired);
    if (desired.deleted === this.state.deleted &&
        (desired.deleted || desired.fingerprint === this.state.fingerprint)) {
      delete this.state.queued;
      return null;
    }
    this.state.pending = {
      expectedRevision: this.state.revision,
      targetRevision: this.state.revision + 1,
      fingerprint: desired.fingerprint,
      deleted: desired.deleted,
    };
    delete this.state.queued;
    return structuredClone(this.state.pending);
  }

  restart() {
    return new PublicationModel(JSON.parse(JSON.stringify(this.state)));
  }

  resolve(remote) {
    const pending = this.state.pending;
    assert.ok(pending);
    if (remote && remote.revision === pending.targetRevision &&
        remote.fingerprint === pending.fingerprint &&
        remote.deleted === pending.deleted) {
      this.state.revision = remote.revision;
      this.state.fingerprint = remote.deleted ? "" : pending.fingerprint;
      this.state.deleted = remote.deleted;
      delete this.state.pending;
      return "accepted";
    }
    const unchanged = remote === null
      ? pending.expectedRevision === 0
      : remote.revision === pending.expectedRevision &&
        remote.deleted === this.state.deleted &&
        (remote.deleted || remote.fingerprint === this.state.fingerprint);
    if (!unchanged) throw new Error("stale remote revision");
    if (!this.state.queued) {
      this.state.queued = {
        fingerprint: pending.fingerprint,
        deleted: pending.deleted,
      };
    }
    delete this.state.pending;
    return "retry";
  }
}

const baseForm = {
  url: "https://example.test/login",
  usernameElement: "username",
  usernameValue: "synthetic-user",
  passwordElement: "password",
  signonRealm: "https://example.test/",
  fingerprint: "a".repeat(64),
};

test("canonical identity follows Chromium's complete PasswordForm unique key", () => {
  const usernameElementVariant = {...baseForm, usernameElement: "email"};
  const passwordElementVariant = {...baseForm, passwordElement: "secret"};
  assert.notEqual(canonicalKey(baseForm), canonicalKey(usernameElementVariant));
  assert.notEqual(canonicalKey(baseForm), canonicalKey(passwordElementVariant));
  assert.equal(legacyKey(baseForm), legacyKey(usernameElementVariant));
  assert.equal(legacyKey(baseForm), legacyKey(passwordElementVariant));
  assert.notEqual(
    canonicalKey({...baseForm, usernameElement: "a\0b"}),
    canonicalKey({...baseForm, usernameElement: "a", usernameValue: "b\0synthetic-user"}),
  );
});

test("schema-3 migration preserves state and refuses an old-key collision", () => {
  const legacy = {
    [legacyKey(baseForm)]: {
      fingerprint: baseForm.fingerprint,
      revision: 7,
      deleted: false,
    },
  };
  const migrated = migrateSchema3(legacy, [baseForm]);
  assert.deepEqual(migrated.legacyCredentials, legacy);
  assert.equal(migrated.canonical[canonicalKey(baseForm)].revision, 0);
  assert.deepEqual(migrated.canonical[canonicalKey(baseForm)].queued, {
    fingerprint: baseForm.fingerprint,
    deleted: false,
  });
  assert.throws(() => migrateSchema3(legacy, [
    baseForm,
    {...baseForm, usernameElement: "email"},
  ]), /legacy identity collision/);
});

test("rapid update and deletion serialize on successive expected revisions", () => {
  const model = new PublicationModel({
    revision: 7,
    fingerprint: "a".repeat(64),
    deleted: false,
  });
  model.observe("b".repeat(64));
  const update = model.begin();
  assert.equal(update.expectedRevision, 7);
  model.observe("deleted", true);
  assert.equal(model.state.queued.deleted, true);
  model.resolve({revision: 8, fingerprint: "b".repeat(64), deleted: false});
  const deletion = model.begin();
  assert.equal(deletion.expectedRevision, 8);
  assert.equal(deletion.targetRevision, 9);
  assert.equal(deletion.deleted, true);
});

test("ambiguous success is durable and resolves by pull after restart", () => {
  const model = new PublicationModel({
    revision: 3,
    fingerprint: "a".repeat(64),
    deleted: false,
  });
  model.observe("b".repeat(64));
  model.begin();
  const restarted = model.restart();
  assert.equal(restarted.resolve({
    revision: 4,
    fingerprint: "b".repeat(64),
    deleted: false,
  }), "accepted");
  assert.equal(restarted.state.revision, 4);
  assert.equal(restarted.state.pending, undefined);
});

test("unaccepted and stale publications retry or fail without false conflict", () => {
  const initial = {
    revision: 5,
    fingerprint: "a".repeat(64),
    deleted: false,
  };
  const retry = new PublicationModel(initial);
  retry.observe("b".repeat(64));
  retry.begin();
  assert.equal(retry.restart().resolve({
    revision: 5,
    fingerprint: "a".repeat(64),
    deleted: false,
  }), "retry");

  const stale = new PublicationModel(initial);
  stale.observe("b".repeat(64));
  stale.begin();
  assert.throws(() => stale.restart().resolve({
    revision: 6,
    fingerprint: "c".repeat(64),
    deleted: false,
  }), /stale remote revision/);
});

test("native source persists one pending publication before one-record push", () => {
  assert.match(source, /kPasswordStateSchema = 4/);
  assert.match(source, /password-form-unique-key-v2/);
  assert.match(source, /credential\/v2\//);
  assert.match(source, /credential\.username_element/);
  assert.match(source, /credential\.password_element/);
  assert.match(source, /AppendU32/);
  assert.match(source, /legacy_credential_state_/);
  assert.match(source, /legacy-preserved/);

  const publish = source.slice(
    source.indexOf("void HeliumPasswordSyncBridge::PublishQueuedMutation"),
    source.indexOf("void HeliumPasswordSyncBridge::OnPushComplete"),
  );
  const pending = publish.indexOf("pending_publication = PendingPublication");
  const durable = publish.indexOf("SaveState()", pending);
  assert.ok(pending >= 0);
  assert.ok(durable > pending);
  assert.ok(publish.indexOf("client_->Push") > durable);
  assert.match(publish, /records\.push_back\(std::move\(mutation\)\)/);

  const callback = source.slice(
    source.indexOf("void HeliumPasswordSyncBridge::OnPushComplete"),
    source.indexOf("void HeliumPasswordSyncBridge::OnPullComplete"),
  );
  assert.match(callback, /PullAndApply\(\)/);
  assert.doesNotMatch(callback, /credential_state_\[/);
  assert.doesNotMatch(callback, /result\.records/);
});
