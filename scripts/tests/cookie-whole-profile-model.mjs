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

export function decideCookieReconcile({ state, remote, localFingerprint }) {
  if (!localFingerprint) throw new Error("local fingerprint is required");
  if (state?.blockedReason) {
    return { action: "stop", reason: state.blockedReason };
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
      return localFingerprint === EMPTY_COOKIE_FINGERPRINT
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
  if (remote.keyId !== state.keyId) {
    return { action: "stop", reason: "key-epoch-changed" };
  }
  if (remote.revision === state.remoteRevision) {
    if (remote.payloadFingerprint !== state.remotePayloadFingerprint) {
      return { action: "stop", reason: "same-revision-payload-changed" };
    }
    return localFingerprint === state.baselineLocalFingerprint
      ? { action: "none" }
      : { action: "publish", expectedRevision: state.remoteRevision };
  }

  return localFingerprint === state.baselineLocalFingerprint
    ? { action: "apply" }
    : { action: "stop", reason: "concurrent-local-and-remote-change" };
}
