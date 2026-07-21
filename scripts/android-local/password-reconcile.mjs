import crypto from "node:crypto";

export const PASSWORD_STATE_SCHEMA = 2;

export function passwordFingerprint(payload) {
  return crypto.createHash("sha256").update(JSON.stringify([
    payload.url,
    payload.signon_realm,
    payload.username,
    payload.password,
    payload.note || "",
  ])).digest("hex");
}

export function normalizePasswordState(parsed) {
  if (parsed?.schema_version === PASSWORD_STATE_SCHEMA) {
    if (!parsed.credentials || typeof parsed.credentials !== "object" ||
        Array.isArray(parsed.credentials)) {
      throw new Error("password state credentials must be an object");
    }
    const credentials = {};
    for (const [key, raw] of Object.entries(parsed.credentials)) {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
        throw new Error(`invalid password state entry: ${key}`);
      }
      const remoteSeq = Number(raw.remote_seq ?? raw.remote_version ?? 0);
      const fingerprint = String(raw.fingerprint || "");
      if (!fingerprint || !Number.isSafeInteger(remoteSeq) || remoteSeq < 0) {
        throw new Error(`invalid password state entry: ${key}`);
      }
      credentials[key] = { fingerprint, remote_seq: remoteSeq };
    }
    return { schema_version: PASSWORD_STATE_SCHEMA, credentials };
  }

  if (parsed?.fingerprints && typeof parsed.fingerprints === "object" &&
      !Array.isArray(parsed.fingerprints)) {
    const credentials = {};
    for (const [key, value] of Object.entries(parsed.fingerprints)) {
      const fingerprint = String(value || "");
      if (fingerprint) credentials[key] = { fingerprint, remote_seq: 0 };
    }
    return { schema_version: PASSWORD_STATE_SCHEMA, credentials };
  }

  return { schema_version: PASSWORD_STATE_SCHEMA, credentials: {} };
}

export async function reconcilePasswords({
  state,
  stateTrusted = true,
  remoteRecords,
  snapshot,
  normalizeRemote,
  applyRemote,
  publish,
}) {
  const before = indexSnapshot(await snapshot());
  const blocked = new Set();
  let applied = 0;

  for (const record of remoteRecords) {
    const remoteSeq = Number(record.seq);
    if (!record.key || record.deleted) {
      continue;
    }
    if (!Number.isSafeInteger(remoteSeq) || remoteSeq <= 0) {
      blocked.add(record.key);
      continue;
    }
    const previous = state.credentials[record.key];
    if (previous && remoteSeq <= previous.remote_seq) continue;

    const payload = normalizeRemote(record.payload);
    if (!payload) {
      blocked.add(record.key);
      continue;
    }
    const fingerprint = passwordFingerprint(payload);
    const local = before.get(record.key);
    if (!local || local.fingerprint !== fingerprint) {
      const ok = await applyRemote(record.key, payload, local?.credential);
      if (!ok) {
        blocked.add(record.key);
        continue;
      }
      applied++;
    }
    state.credentials[record.key] = {
      fingerprint,
      remote_seq: remoteSeq,
    };
  }

  const after = indexSnapshot(await snapshot());
  const records = [];
  for (const [key, local] of after) {
    if (blocked.has(key)) continue;
    const previous = state.credentials[key];
    if (!stateTrusted && !previous) {
      state.credentials[key] = {
        fingerprint: local.fingerprint,
        remote_seq: 0,
      };
      continue;
    }
    if (previous?.fingerprint === local.fingerprint) continue;
    records.push({ kind: "passwords", key, payload: local.payload });
  }

  if (records.length) {
    await publish(records);
    for (const record of records) {
      const local = after.get(record.key);
      state.credentials[record.key] = {
        fingerprint: local.fingerprint,
        remote_seq: state.credentials[record.key]?.remote_seq || 0,
      };
    }
  }

  return { applied, published: records.length, blocked: blocked.size };
}

function indexSnapshot(credentials) {
  const indexed = new Map();
  for (const credential of credentials) {
    if (!credential?.key || !credential.payload) continue;
    indexed.set(credential.key, {
      credential: credential.credential,
      payload: credential.payload,
      fingerprint: passwordFingerprint(credential.payload),
    });
  }
  return indexed;
}
