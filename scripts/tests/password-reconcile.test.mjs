import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizePasswordState,
  passwordFingerprint,
  reconcilePasswords,
} from "../android-local/password-reconcile.mjs";

const payload = (password) => ({
  format: "helium-password-v1",
  url: "https://fixture.invalid/login",
  signon_realm: "https://fixture.invalid/",
  username: "fixture-user",
  password,
  note: "",
});

function harness({ localPassword, state, remote = [], stateTrusted = true }) {
  let local = localPassword ? payload(localPassword) : null;
  const published = [];
  return {
    state,
    published,
    local: () => local,
    run: () => reconcilePasswords({
      state,
      stateTrusted,
      remoteRecords: remote,
      snapshot: async () => local ? [{ key: "credential/fixture", payload: local }] : [],
      normalizeRemote: (value) => value?.format === "helium-password-v1" ? value : null,
      applyRemote: async (_key, remotePayload) => {
        local = remotePayload;
        return true;
      },
      publish: async (records) => published.push(...records),
    }),
  };
}

test("unchanged restart publishes nothing", async () => {
  const current = payload("current");
  const state = normalizePasswordState({
    schema_version: 2,
    credentials: {
      "credential/fixture": {
        fingerprint: passwordFingerprint(current),
        remote_seq: 41,
      },
    },
  });
  const testRun = harness({
    localPassword: "current",
    state,
    remote: [{ key: "credential/fixture", seq: 41, payload: current }],
  });

  assert.deepEqual(await testRun.run(), { applied: 0, published: 0, blocked: 0 });
  assert.deepEqual(testRun.published, []);
});

test("newer remote password replaces stale local without republishing it", async () => {
  const old = payload("old");
  const newer = payload("newer");
  const state = normalizePasswordState({
    schema_version: 2,
    credentials: {
      "credential/fixture": {
        fingerprint: passwordFingerprint(old),
        remote_seq: 10,
      },
    },
  });
  const testRun = harness({
    localPassword: "stale-offline-edit",
    state,
    remote: [{ key: "credential/fixture", seq: 11, payload: newer }],
  });

  assert.deepEqual(await testRun.run(), { applied: 1, published: 0, blocked: 0 });
  assert.equal(testRun.local().password, "newer");
  assert.deepEqual(testRun.published, []);
  assert.equal(state.credentials["credential/fixture"].remote_seq, 11);
});

test("actual offline local mutation publishes after an unchanged remote baseline", async () => {
  const previous = payload("previous");
  const state = normalizePasswordState({
    schema_version: 2,
    credentials: {
      "credential/fixture": {
        fingerprint: passwordFingerprint(previous),
        remote_seq: 7,
      },
    },
  });
  const testRun = harness({
    localPassword: "local-edit",
    state,
    remote: [{ key: "credential/fixture", seq: 7, payload: previous }],
  });

  assert.deepEqual(await testRun.run(), { applied: 0, published: 1, blocked: 0 });
  assert.equal(testRun.published[0].payload.password, "local-edit");
});

test("a corrupt-state recovery establishes a baseline without publishing", async () => {
  const state = normalizePasswordState(null);
  const testRun = harness({
    localPassword: "preserved-local",
    state,
    stateTrusted: false,
  });

  assert.deepEqual(await testRun.run(), { applied: 0, published: 0, blocked: 0 });
  assert.equal(
    state.credentials["credential/fixture"].fingerprint,
    passwordFingerprint(payload("preserved-local")),
  );
});

test("legacy fingerprint state migrates without an unchanged republish", async () => {
  const current = payload("legacy-current");
  const state = normalizePasswordState({
    fingerprints: { "credential/fixture": passwordFingerprint(current) },
  });
  const testRun = harness({ localPassword: "legacy-current", state });

  assert.deepEqual(await testRun.run(), { applied: 0, published: 0, blocked: 0 });
  assert.equal(state.schema_version, 2);
});

test("invalid durable or remote metadata fails closed", async () => {
  assert.throws(() => normalizePasswordState({
    schema_version: 2,
    credentials: { "credential/fixture": { fingerprint: "", remote_seq: -1 } },
  }), /invalid password state entry/);

  const state = normalizePasswordState(null);
  const testRun = harness({
    localPassword: "local-value",
    state,
    remote: [{ key: "credential/fixture", seq: "not-a-sequence", payload: payload("remote") }],
  });
  assert.deepEqual(await testRun.run(), { applied: 0, published: 0, blocked: 1 });
});
