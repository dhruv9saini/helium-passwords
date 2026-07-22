export const EMPTY_COOKIE_FINGERPRINT = "empty";

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

