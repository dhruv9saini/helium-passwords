import { createHash } from "node:crypto";

export const EMPTY_COOKIE_FINGERPRINT = "empty";

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort()
    .map(key => [key, stableValue(value[key])]));
}

function stableJSON(value) {
  return JSON.stringify(stableValue(value));
}

export function canonicalCookieIdentity(cookie) {
  if (!cookie || typeof cookie !== "object" ||
      typeof cookie.name !== "string" ||
      typeof cookie.domain !== "string" || !cookie.domain ||
      typeof cookie.path !== "string" || !cookie.path ||
      !["string", "number"].includes(typeof cookie.sourceScheme) ||
      !Number.isInteger(cookie.sourcePort) || cookie.sourcePort < -1 ||
      cookie.sourcePort > 65535) {
    throw new Error("invalid canonical cookie identity");
  }
  const parts = [];
  if (cookie.partitionKey === undefined || cookie.partitionKey === null) {
    parts.push("unpartitioned");
  } else {
    const partition = cookie.partitionKey;
    if (typeof partition !== "object" ||
        typeof partition.topLevelSite !== "string" ||
        !partition.topLevelSite ||
        typeof partition.hasCrossSiteAncestor !== "boolean") {
      throw new Error("invalid canonical cookie partition key");
    }
    parts.push("partitioned", partition.topLevelSite,
      partition.hasCrossSiteAncestor ? "1" : "0");
  }
  parts.push(cookie.domain, cookie.path, cookie.name,
    String(cookie.sourceScheme), String(cookie.sourcePort));
  const framed = parts.map(part => `${Buffer.byteLength(part, "utf8")}:${part}`).join("");
  return createHash("sha256").update(framed).digest("hex");
}

function cookieMap(cookies) {
  if (!Array.isArray(cookies)) throw new Error("cookies must be an array");
  const result = new Map();
  for (const cookie of cookies) {
    const identity = canonicalCookieIdentity(cookie);
    if (result.has(identity)) throw new Error("duplicate canonical cookie identity");
    result.set(identity, structuredClone(cookie));
  }
  return result;
}

function cookiesFromMap(cookies) {
  return [...cookies.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([, cookie]) => structuredClone(cookie));
}

function cookieSetFingerprint(cookies) {
  const mapped = cookieMap(cookies);
  const canonical = [...mapped.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([identity, cookie]) => [identity, stableValue(cookie)]);
  return createHash("sha256").update(stableJSON(canonical)).digest("hex");
}

export function previewCookieTransaction(beforeCookies, updates) {
  if (!Array.isArray(updates)) throw new Error("cookie updates must be an array");
  const before = cookieMap(beforeCookies);
  const target = new Map(before);
  const touched = new Set();
  for (const update of updates) {
    if (!update || !["set", "delete"].includes(update.action)) {
      throw new Error("invalid cookie update action");
    }
    const identity = canonicalCookieIdentity(update.cookie);
    if (touched.has(identity)) throw new Error("duplicate cookie update identity");
    touched.add(identity);
    if (update.action === "set") target.set(identity, structuredClone(update.cookie));
    else target.delete(identity);
  }

  const operations = [];
  for (const identity of [...touched].sort()) {
    const beforeCookie = before.get(identity);
    const targetCookie = target.get(identity);
    if (targetCookie === undefined) {
      if (beforeCookie !== undefined) operations.push({ action: "delete", identity });
    } else if (beforeCookie === undefined ||
               stableJSON(beforeCookie) !== stableJSON(targetCookie)) {
      operations.push({ action: "set", identity, cookie: structuredClone(targetCookie) });
    }
  }
  const normalizedBefore = cookiesFromMap(before);
  const normalizedTarget = cookiesFromMap(target);
  return {
    beforeCookies: normalizedBefore,
    targetCookies: normalizedTarget,
    beforeFingerprint: cookieSetFingerprint(normalizedBefore),
    targetFingerprint: cookieSetFingerprint(normalizedTarget),
    setCount: operations.filter(operation => operation.action === "set").length,
    deleteCount: operations.filter(operation => operation.action === "delete").length,
    operations,
  };
}

export function applyCookieTransaction(preview, { rejectIdentity = "" } = {}) {
  if (cookieSetFingerprint(preview.beforeCookies) !== preview.beforeFingerprint ||
      cookieSetFingerprint(preview.targetCookies) !== preview.targetFingerprint) {
    throw new Error("cookie transaction preview fingerprint mismatch");
  }
  const working = cookieMap(preview.beforeCookies);
  for (const operation of preview.operations) {
    if (operation.identity === rejectIdentity) continue;
    if (operation.action === "set") {
      working.set(operation.identity, structuredClone(operation.cookie));
    } else {
      working.delete(operation.identity);
    }
  }
  const applied = cookiesFromMap(working);
  if (cookieSetFingerprint(applied) === preview.targetFingerprint) {
    return { status: "committed", cookies: applied };
  }
  const rollback = structuredClone(preview.beforeCookies);
  if (cookieSetFingerprint(rollback) !== preview.beforeFingerprint) {
    throw new Error("cookie rollback verification failed");
  }
  return { status: "rolled-back", cookies: rollback };
}

export function scopeDestinationRejection({
  cookie,
  remote,
  site,
  observedSessions = [],
}) {
  const recordKey = canonicalCookieIdentity(cookie);
  if (!remote || remote.recordKey !== recordKey ||
      !Number.isInteger(remote.revision) || remote.revision <= 0 ||
      typeof remote.payloadFingerprint !== "string" ||
      !remote.payloadFingerprint || typeof site !== "string" || !site) {
    throw new Error("invalid rejected remote cookie scope");
  }
  const seen = new Set();
  const sessions = observedSessions.filter(session => session?.site === site)
    .map(session => {
      if (!session || typeof session.site !== "string" || !session.site ||
          typeof session.sessionId !== "string" || !session.sessionId) {
        throw new Error("invalid observed device-bound session identity");
      }
      const identity = `${Buffer.byteLength(session.site, "utf8")}:${session.site}` +
        `${Buffer.byteLength(session.sessionId, "utf8")}:${session.sessionId}`;
      if (seen.has(identity)) {
        throw new Error("duplicate observed device-bound session identity");
      }
      seen.add(identity);
      return structuredClone(session);
    }).sort((left, right) => stableJSON(left).localeCompare(stableJSON(right)));
  return {
    recordKey,
    remoteRevision: remote.revision,
    remotePayloadFingerprint: remote.payloadFingerprint,
    reason: "destination-set-rejected",
    site,
    observedSessions: sessions,
  };
}

export function migrateCookieStateV2(document) {
  if (!document || document.schema_version !== 2 ||
      !document.records || typeof document.records !== "object" ||
      Array.isArray(document.records)) {
    throw new Error("invalid cookie state schema 2 document");
  }
  const migrated = structuredClone(document);
  migrated.schema_version = 3;
  for (const record of Object.values(migrated.records)) {
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      throw new Error("invalid cookie state schema 2 record");
    }
    delete record.non_clonable;
    delete record.non_clonable_reason;
    delete record.site;
  }
  return migrated;
}

export function decideCookieReconcile({
  state,
  remote,
  localFingerprint,
  activeKeyId,
  recordKey = "",
  pendingEnrollment = false,
}) {
  if (!localFingerprint) throw new Error("local fingerprint is required");
  if (typeof activeKeyId !== "string" || !activeKeyId) {
    throw new Error("active content key id is required");
  }
  if (state?.blockedReason) {
    return { action: "stop", reason: state.blockedReason };
  }
  if (state?.destinationException &&
      (state.destinationException.recordKey !== recordKey ||
       state.destinationException.remoteRevision !== state.remoteRevision ||
       state.destinationException.remotePayloadFingerprint !==
         state.remotePayloadFingerprint)) {
    return { action: "stop", reason: "destination-exception-scope-mismatch" };
  }

  if (state?.pendingPublish) {
    const pending = state.pendingPublish;
    if (!remote || remote.deleted) {
      if (pending.expectedRevision !== 0) {
        return { action: "stop", reason: "pending-publication-authority-regressed" };
      }
      return localFingerprint === pending.localFingerprint
        ? { action: "publish", expectedRevision: 0 }
        : { action: "stop", reason: "local-changed-during-unconfirmed-publication" };
    }
    if (remote.revision === pending.targetRevision &&
        remote.payloadFingerprint === pending.payloadFingerprint) {
      if (remote.keyId !== activeKeyId) {
        return { action: "stop", reason: "publication-confirmed-under-stale-key-epoch" };
      }
      return { action: "accept-publication" };
    }
    if (remote.revision === pending.expectedRevision &&
        remote.payloadFingerprint === state.remotePayloadFingerprint &&
        localFingerprint === pending.localFingerprint) {
      return { action: "publish", expectedRevision: pending.expectedRevision };
    }
    return { action: "stop", reason: "publication-cas-conflict" };
  }

  if (!state || state.remoteRevision === 0) {
    if (remote && !remote.deleted) {
      if (remote.keyId !== activeKeyId) {
        return { action: "stop", reason: "initial-record-uses-stale-key-epoch" };
      }
      return pendingEnrollment || localFingerprint === EMPTY_COOKIE_FINGERPRINT
        ? { action: "apply" }
        : { action: "stop", reason: "uninitialized-local-and-remote-state" };
    }
    return localFingerprint === EMPTY_COOKIE_FINGERPRINT
      ? { action: "none" }
      : { action: "publish", expectedRevision: 0 };
  }

  if (!remote || remote.revision < state.remoteRevision) {
    return { action: "stop", reason: "authority-revision-regressed" };
  }
  if (remote.revision === state.remoteRevision) {
    if (remote.keyId !== state.keyId) {
      return { action: "stop", reason: "same-revision-key-epoch-changed" };
    }
    if (remote.payloadFingerprint !== state.remotePayloadFingerprint) {
      return { action: "stop", reason: "same-revision-payload-changed" };
    }
    return localFingerprint === state.baselineLocalFingerprint
      ? { action: "none" }
      : { action: "publish", expectedRevision: state.remoteRevision };
  }

  if (remote.keyId !== activeKeyId) {
    return { action: "stop", reason: "newer-record-uses-stale-key-epoch" };
  }

  return localFingerprint === state.baselineLocalFingerprint
    ? { action: "apply" }
    : { action: "stop", reason: "concurrent-local-and-remote-change" };
}
