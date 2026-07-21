import assert from "node:assert/strict";
import test from "node:test";

import {
  cookieIdentity,
  cookieToCDPParams,
  emptyCookiePayload,
  migrateCookiePayload,
  replicaGeneration,
  updateDomainFromSource,
  validateCookiePolicies,
} from "../android-local/cookie-replication.mjs";

const policies = validateCookiePolicies([
  { domain: "fixture.invalid", source: "oneplus", replicas: ["d", "da"], mode: "portable" },
  { domain: "bound.invalid", source: "d", replicas: ["oneplus"], mode: "device-bound" },
]);
const portable = policies[0];
const baseCookie = {
  name: "session",
  value: "generation-one",
  domain: ".fixture.invalid",
  path: "/",
  expires: 4102444800,
  httpOnly: true,
  secure: true,
  session: false,
  sameSite: "None",
  priority: "High",
  sourceScheme: "Secure",
  sourcePort: 443,
};

test("complete identity keeps unpartitioned and two partitioned cookies separate", () => {
  const unpartitioned = baseCookie;
  const first = {
    ...baseCookie,
    partitionKey: { topLevelSite: "https://first.invalid", hasCrossSiteAncestor: false },
  };
  const second = {
    ...baseCookie,
    partitionKey: { topLevelSite: "https://second.invalid", hasCrossSiteAncestor: true },
  };

  assert.equal(new Set([unpartitioned, first, second].map(cookieIdentity)).size, 3);
  assert.notEqual(cookieIdentity(baseCookie), cookieIdentity({ ...baseCookie, domain: "fixture.invalid" }));
  assert.deepEqual(cookieToCDPParams(second).partitionKey, second.partitionKey);
  assert.equal(cookieToCDPParams(second).sourcePort, 443);
  assert.equal(cookieToCDPParams(second).priority, "High");
});

test("legacy schema migration requires an explicit source and preserves attributes", () => {
  assert.throws(
    () => migrateCookiePayload({ cookie_data: { legacy: [baseCookie] } }, policies),
    /legacy_source_device/,
  );
  const migrated = migrateCookiePayload(
    { cookie_data: { legacy: [baseCookie] } },
    policies,
    "oneplus",
  );
  assert.equal(migrated.schema_version, 2);
  assert.equal(migrated.domains[portable.domain].source_device, "oneplus");
  assert.equal(migrated.domains[portable.domain].cookies[0].httpOnly, true);
  assert.equal(migrated.domains[portable.domain].cookies[0].sourceScheme, "Secure");
});

test("malformed schema-v2 cookie generation is rejected before replica apply", () => {
  assert.throws(() => migrateCookiePayload({
    schema_version: 2,
    domains: {
      "fixture.invalid": {
        source_device: "oneplus",
        mode: "portable",
        generation: 3,
        cookies: [{ ...baseCookie, sourcePort: 0 }],
      },
    },
  }, policies), /invalid cookie in generation/);
});

test("only the configured source can publish a rotating generation", () => {
  const payload = emptyCookiePayload();
  assert.throws(
    () => updateDomainFromSource(payload, portable, "d", [baseCookie]),
    /is not the source/,
  );
  assert.equal(updateDomainFromSource(payload, portable, "oneplus", [baseCookie]), true);
  assert.equal(payload.domains[portable.domain].generation, 1);
  assert.equal(updateDomainFromSource(payload, portable, "oneplus", [baseCookie]), false);

  const rotated = { ...baseCookie, value: "generation-two" };
  assert.equal(updateDomainFromSource(payload, portable, "oneplus", [rotated]), true);
  assert.equal(payload.domains[portable.domain].generation, 2);
  assert.equal(replicaGeneration(payload, portable, "d").cookies[0].value, "generation-two");
});

test("replica state never becomes source input", () => {
  const payload = emptyCookiePayload();
  updateDomainFromSource(payload, portable, "oneplus", [baseCookie]);
  const staleReplicaCookie = { ...baseCookie, value: "stale-replica" };

  assert.throws(
    () => updateDomainFromSource(payload, portable, "da", [staleReplicaCookie]),
    /is not the source/,
  );
  assert.equal(replicaGeneration(payload, portable, "d").cookies[0].value, "generation-one");
});

test("device-bound policy returns reauthentication without copying cookies", () => {
  const payload = emptyCookiePayload();
  const bound = policies[1];
  updateDomainFromSource(payload, bound, "d", [{ ...baseCookie, domain: "bound.invalid" }]);

  assert.deepEqual(replicaGeneration(payload, bound, "oneplus"), {
    action: "reauthenticate",
    generation: 1,
    cookies: [],
  });
  assert.deepEqual(payload.domains[bound.domain].cookies, []);
});
