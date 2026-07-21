export const COOKIE_PAYLOAD_SCHEMA = 2;

export function validateCookiePolicies(rawPolicies) {
  if (!Array.isArray(rawPolicies) || rawPolicies.length === 0) {
    throw new Error("cookie_policies must be a non-empty array");
  }
  const domains = new Set();
  return rawPolicies.map((raw) => {
    const domain = canonicalDomain(raw?.domain);
    const source = String(raw?.source || "").trim();
    const replicas = Array.isArray(raw?.replicas)
      ? [...new Set(raw.replicas.map(String).map(value => value.trim()).filter(Boolean))]
      : [];
    const mode = String(raw?.mode || "");
    if (!domain || !source) throw new Error("each cookie policy requires domain and source");
    if (domains.has(domain)) throw new Error(`duplicate cookie policy for ${domain}`);
    if (replicas.includes(source)) throw new Error(`cookie source cannot replicate to itself: ${domain}`);
    if (!['portable', 'device-bound'].includes(mode)) {
      throw new Error(`cookie policy mode must be portable or device-bound: ${domain}`);
    }
    domains.add(domain);
    return { domain, source, replicas, mode };
  });
}

export function emptyCookiePayload() {
  return { schema_version: COOKIE_PAYLOAD_SCHEMA, domains: {} };
}

export function migrateCookiePayload(raw, policies, legacySourceDevice = "") {
  if (raw?.schema_version === COOKIE_PAYLOAD_SCHEMA) {
    return validateCookiePayload(raw, policies);
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || !raw.cookie_data) {
    return emptyCookiePayload();
  }
  if (!legacySourceDevice) {
    throw new Error("legacy cookie payload requires legacy_source_device");
  }

  const out = emptyCookiePayload();
  const allCookies = Object.values(raw.cookie_data).flatMap(value => Array.isArray(value) ? value : []);
  for (const policy of policies) {
    if (policy.source !== legacySourceDevice) continue;
    const cookies = policy.mode === "portable"
      ? normalizeCookieSet(allCookies.filter(cookie => domainMatchesPolicy(cookie?.domain, policy.domain)))
      : [];
    out.domains[policy.domain] = {
      source_device: policy.source,
      mode: policy.mode,
      generation: 1,
      cookies,
    };
  }
  return out;
}

export function updateDomainFromSource(payload, policy, sourceDevice, rawCookies) {
  if (sourceDevice !== policy.source) {
    throw new Error(`${sourceDevice} is not the source for ${policy.domain}`);
  }
  const cookies = policy.mode === "portable"
    ? normalizeCookieSet(rawCookies.filter(cookie => domainMatchesPolicy(cookie?.domain, policy.domain)))
    : [];
  const current = payload.domains[policy.domain];
  const unchanged = current &&
    current.source_device === policy.source &&
    current.mode === policy.mode &&
    JSON.stringify(current.cookies) === JSON.stringify(cookies);
  if (unchanged) return false;
  payload.domains[policy.domain] = {
    source_device: policy.source,
    mode: policy.mode,
    generation: (current?.generation || 0) + 1,
    cookies,
  };
  return true;
}

export function replicaGeneration(payload, policy, device) {
  if (!policy.replicas.includes(device)) {
    return { action: "none", generation: 0, cookies: [] };
  }
  const domain = payload.domains[policy.domain];
  if (!domain) return { action: "none", generation: 0, cookies: [] };
  if (domain.source_device !== policy.source || domain.mode !== policy.mode) {
    throw new Error(`remote cookie policy mismatch for ${policy.domain}`);
  }
  if (policy.mode === "device-bound") {
    return { action: "reauthenticate", generation: domain.generation, cookies: [] };
  }
  return { action: "apply", generation: domain.generation, cookies: domain.cookies };
}

export function normalizeCookie(raw) {
  if (!raw || !raw.name || !raw.domain || raw.partitionKeyOpaque) return null;
  const expires = Number(raw.expires ?? raw.expirationDate ?? -1);
  if (!Number.isFinite(expires)) return null;
  const sourcePort = Number(raw.sourcePort ?? -1);
  if (!Number.isInteger(sourcePort) || sourcePort < -1 || sourcePort === 0 || sourcePort > 65535) return null;
  const partitionKey = normalizePartitionKey(raw.partitionKey);
  if (raw.partitionKey && !partitionKey) return null;
  const out = {
    name: String(raw.name),
    value: String(raw.value || ""),
    domain: String(raw.domain).toLowerCase(),
    path: String(raw.path || "/"),
    expires,
    size: Number.isInteger(raw.size) && raw.size >= 0 ? raw.size : undefined,
    httpOnly: Boolean(raw.httpOnly),
    secure: Boolean(raw.secure),
    session: Boolean(raw.session ?? expires <= 0),
    sameSite: ["Strict", "Lax", "None"].includes(raw.sameSite) ? raw.sameSite : "Unspecified",
    priority: ["Low", "Medium", "High"].includes(raw.priority) ? raw.priority : "Medium",
    sameParty: Boolean(raw.sameParty),
    sourceScheme: ["Unset", "NonSecure", "Secure"].includes(raw.sourceScheme)
      ? raw.sourceScheme
      : "Unset",
    sourcePort,
    partitionKey,
  };
  if (out.size === undefined) delete out.size;
  if (!partitionKey) delete out.partitionKey;
  return out;
}

export function cookieIdentity(raw) {
  const cookie = normalizeCookie(raw);
  if (!cookie) return "";
  const partition = cookie.partitionKey
    ? `${cookie.partitionKey.topLevelSite}\0${cookie.partitionKey.hasCrossSiteAncestor}`
    : "unpartitioned";
  return [
    partition,
    cookie.domain,
    cookie.path,
    cookie.name,
    cookie.sourceScheme,
    cookie.sourcePort,
  ].join("\0");
}

export function cookieToCDPParams(raw) {
  const cookie = normalizeCookie(raw);
  if (!cookie) return null;
  const params = {
    name: cookie.name,
    value: cookie.value,
    domain: cookie.domain,
    path: cookie.path,
    secure: cookie.secure,
    httpOnly: cookie.httpOnly,
    priority: cookie.priority,
    sourceScheme: cookie.sourceScheme,
    sourcePort: cookie.sourcePort,
    url: `${cookie.secure ? "https" : "http"}://${cookie.domain.replace(/^\./, "")}${cookie.path}`,
  };
  if (cookie.sameSite !== "Unspecified") params.sameSite = cookie.sameSite;
  if (!cookie.session && cookie.expires > 0) params.expires = cookie.expires;
  if (cookie.partitionKey) params.partitionKey = cookie.partitionKey;
  return params;
}

export function cookieToDeleteParams(raw) {
  const cookie = normalizeCookie(raw);
  if (!cookie) return null;
  const params = {
    name: cookie.name,
    domain: cookie.domain,
    path: cookie.path,
  };
  if (cookie.partitionKey) params.partitionKey = cookie.partitionKey;
  return params;
}

function validateCookiePayload(raw, policies) {
  if (!raw.domains || typeof raw.domains !== "object" || Array.isArray(raw.domains)) {
    throw new Error("cookie payload domains must be an object");
  }
  const out = emptyCookiePayload();
  const policyByDomain = new Map(policies.map(policy => [policy.domain, policy]));
  for (const [domain, value] of Object.entries(raw.domains)) {
    const policy = policyByDomain.get(canonicalDomain(domain));
    if (!policy || !value || typeof value !== "object") continue;
    const generation = Number(value.generation);
    if (!Number.isSafeInteger(generation) || generation <= 0 ||
        value.source_device !== policy.source || value.mode !== policy.mode) {
      throw new Error(`invalid cookie generation for ${domain}`);
    }
    out.domains[policy.domain] = {
      source_device: policy.source,
      mode: policy.mode,
      generation,
      cookies: policy.mode === "portable" ? normalizeCookieSet(value.cookies, true) : [],
    };
  }
  return out;
}

function normalizeCookieSet(rawCookies, strict = false) {
  if (!Array.isArray(rawCookies)) {
    if (strict) throw new Error("cookie generation cookies must be an array");
    return [];
  }
  const byIdentity = new Map();
  for (const raw of rawCookies) {
    const cookie = normalizeCookie(raw);
    if (!cookie) {
      if (strict) throw new Error("invalid cookie in generation");
      continue;
    }
    if (cookieIsExpired(cookie)) continue;
    byIdentity.set(cookieIdentity(cookie), cookie);
  }
  return [...byIdentity.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([, cookie]) => cookie);
}

function cookieIsExpired(cookie, now = Date.now() / 1000) {
  return !cookie.session && cookie.expires > 0 && cookie.expires <= now;
}

function normalizePartitionKey(raw) {
  if (!raw) return null;
  const topLevelSite = String(raw.topLevelSite || "");
  if (!topLevelSite) return null;
  return {
    topLevelSite,
    hasCrossSiteAncestor: Boolean(raw.hasCrossSiteAncestor),
  };
}

function canonicalDomain(value) {
  return String(value || "").trim().toLowerCase().replace(/^\./, "");
}

function domainMatchesPolicy(cookieDomain, policyDomain) {
  const domain = canonicalDomain(cookieDomain);
  return domain === policyDomain || domain.endsWith(`.${policyDomain}`);
}
