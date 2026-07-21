import assert from "node:assert/strict";
import test from "node:test";

import {startPasswordLifecycleFixture} from "../password-lifecycle-fixture.mjs";

test("password lifecycle fixture is loopback-only and never reflects values", async () => {
  const fixture = await startPasswordLifecycleFixture();
  const origin = new URL(fixture.origin);
  assert.equal(origin.hostname, "127.0.0.1");
  assert.notEqual(origin.port, "0");

  const submitted = [
    "fixture-user-never-echo",
    "fixture-current-never-echo",
    "fixture-new-never-echo",
  ];

  try {
    const login = await fetch(`${fixture.origin}/login`);
    const loginHtml = await login.text();
    assert.equal(login.status, 200);
    assert.match(loginHtml, /action="\/session"/);
    assert.match(loginHtml, /name="username" autocomplete="username"/);
    assert.match(loginHtml, /name="password" type="password" autocomplete="current-password"/);

    const session = await fetch(`${fixture.origin}/session`, {
      method: "POST",
      redirect: "manual",
      body: new URLSearchParams({username: submitted[0], password: submitted[1]}),
    });
    assert.equal(session.status, 303);
    assert.equal(session.headers.get("location"), "/account");
    assert.match(session.headers.get("set-cookie"), /^fixture_session=1;/);
    assert.equal(await session.text(), "");

    const change = await fetch(`${fixture.origin}/change-password`);
    const changeHtml = await change.text();
    assert.match(changeHtml, /action="\/password"/);
    assert.match(changeHtml, /name="username" autocomplete="username"/);
    assert.match(changeHtml, /name="current_password" type="password" autocomplete="current-password"/);
    assert.equal((changeHtml.match(/autocomplete="new-password"/g) ?? []).length, 2);

    const update = await fetch(`${fixture.origin}/password`, {
      method: "POST",
      redirect: "manual",
      body: new URLSearchParams({
        username: submitted[0],
        current_password: submitted[1],
        new_password: submitted[2],
        confirm_password: submitted[2],
      }),
    });
    assert.equal(update.status, 303);
    assert.equal(update.headers.get("location"), "/updated");
    assert.equal(await update.text(), "");

    const visibleBodies = [loginHtml, changeHtml];
    visibleBodies.push(await (await fetch(`${fixture.origin}/account`)).text());
    visibleBodies.push(await (await fetch(`${fixture.origin}/updated`)).text());
    for (const body of visibleBodies) {
      for (const value of submitted) assert.doesNotMatch(body, new RegExp(value));
    }

    assert.equal((await fetch(`${fixture.origin}/healthz`)).status, 200);
    assert.equal((await fetch(`${fixture.origin}/missing`)).status, 404);
  } finally {
    await fixture.close();
  }

  await assert.rejects(fetch(`${fixture.origin}/healthz`));
});
