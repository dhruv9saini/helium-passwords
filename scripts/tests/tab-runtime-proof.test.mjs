import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {execFileSync, spawnSync} from "node:child_process";
import test from "node:test";

const repo = path.resolve(new URL("../..", import.meta.url).pathname);
const runtime = path.join(repo, "scripts/tabs/tab-runtime-proof.mjs");
const status = path.join(repo, "scripts/tabs/tab-proof-status.mjs");
const health = path.join(repo, "scripts/tabs/tab-recovery-health.sh");

function run(file, args, options = {}) {
  const result = spawnSync(file, args, {
    cwd: repo,
    encoding: "utf8",
    ...options,
  });
  if (result.status !== 0 || result.signal !== null) {
    throw new Error(
      `${file} ${args.join(" ")} failed\nstdout=${result.stdout}\nstderr=${result.stderr}`);
  }
  return result.stdout.trim();
}

function failRun(file, args) {
  const result = spawnSync(file, args, {
    cwd: repo,
    encoding: "utf8",
  });
  assert.notEqual(result.status, 0, result.stdout);
  return result;
}

function sha256File(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function writePrivate(file, value) {
  fs.writeFileSync(file, value, {mode: 0o600});
  fs.chmodSync(file, 0o600);
}

function writeFakeBrowser(file) {
  writePrivate(file, `#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const option = name => {
  const prefix = \`--\${name}=\`;
  const value = process.argv.slice(2).find(argument => argument.startsWith(prefix));
  return value?.slice(prefix.length);
};
const profile = option("user-data-dir");
if (!profile || !path.isAbsolute(profile) ||
    !process.argv.includes("--remote-debugging-pipe")) {
  process.exit(70);
}
const stateFile = path.join(profile, "fake-session.json");
let serial = 1;
const newTarget = url => ({
  targetId: \`target-\${process.pid}-\${serial++}\`,
  url,
});
let windows;
if (process.argv.some(argument =>
    argument.startsWith("--helium-restore-disposable-tabs="))) {
  const source = JSON.parse(fs.readFileSync(
    path.join(profile, "restore-source/session.json"), "utf8"));
  windows = source.windows.map((window, index) => ({
    id: index + 1,
    targets: window.tabs.map(tab => newTarget(
      tab.navigations[tab.current_index].url)),
  }));
  const manifest = JSON.parse(fs.readFileSync(
    path.join(profile, "browser-restore-manifest.json"), "utf8"));
  const requestedDevice = option("helium-restore-disposable-tabs");
  const receipt = {
    schema_version: 2,
    state: "applied",
    source_generation: manifest.source_generation,
    source_device: requestedDevice,
    source_profile: manifest.source_profile,
    source_session_sha256: manifest.source_session.sha256,
    window_count: manifest.window_count,
    tab_count: manifest.tab_count,
    group_count: manifest.group_count,
    readback_validation: "exact-supported-live-topology",
    completed_at_unix_millis: String(Date.now()),
    error: "",
  };
  fs.writeFileSync(path.join(profile,
    ".helium-tabs-restore-receipt-v2.json"),
    \`\${JSON.stringify(receipt, null, 2)}\\n\`, {mode: 0o600});
  fs.renameSync(path.join(profile, ".helium-tabs-restore-prepared-v2"),
    path.join(profile, ".helium-tabs-restore-consumed-v2"));
} else if (process.argv.includes("--restore-last-session") &&
           fs.existsSync(stateFile)) {
  windows = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  for (const window of windows) {
    for (const target of window.targets) {
      const match = /-(\\d+)$/.exec(target.targetId);
      serial = Math.max(serial, Number(match?.[1] ?? 0) + 1);
    }
  }
} else {
  windows = [{id: 1, targets: [newTarget("about:blank")]}];
}
const sessions = new Map();
const persist = () => {
  const temporary = \`\${stateFile}.tmp\`;
  fs.writeFileSync(temporary, \`\${JSON.stringify(windows)}\\n\`, {mode: 0o600});
  fs.renameSync(temporary, stateFile);
};
persist();

const input = fs.createReadStream("/dev/null", {fd: 3, autoClose: false});
const output = fs.createWriteStream("/dev/null", {fd: 4, autoClose: false});
let buffer = Buffer.alloc(0);
const send = message => {
  output.write(Buffer.concat([
    Buffer.from(JSON.stringify(message)),
    Buffer.from([0]),
  ]));
};
const findTarget = id => {
  for (const window of windows) {
    const target = window.targets.find(candidate => candidate.targetId === id);
    if (target) return {window, target};
  }
  return undefined;
};
const handle = message => {
  let result = {};
  switch (message.method) {
    case "Browser.getVersion":
      result = {
        protocolVersion: "1.3",
        product: "Helium/FakePinned",
        revision: "fake-revision",
        userAgent: "Helium fake browser",
        jsVersion: "fake-v8",
      };
      break;
    case "Target.getTargets":
      result = {
        targetInfos: windows.flatMap(window => window.targets.map(target => ({
          targetId: target.targetId,
          type: "page",
          title: "",
          url: target.url,
          attached: false,
          browserContextId: "default",
        }))),
      };
      break;
    case "Target.attachToTarget": {
      const sessionId = \`session-\${message.params.targetId}\`;
      sessions.set(sessionId, message.params.targetId);
      result = {sessionId};
      break;
    }
    case "Page.enable":
      break;
    case "Page.navigate": {
      const target = findTarget(sessions.get(message.sessionId));
      if (!target) throw new Error("unknown session");
      target.target.url = message.params.url;
      persist();
      result = {frameId: "frame"};
      break;
    }
    case "Target.closeTarget": {
      const target = findTarget(message.params.targetId);
      if (!target) throw new Error("unknown target");
      target.window.targets = target.window.targets.filter(candidate =>
        candidate.targetId !== message.params.targetId);
      windows = windows.filter(window => window.targets.length > 0);
      persist();
      result = {success: true};
      break;
    }
    case "Target.createTarget": {
      if (windows.length === 0) windows.push({id: 1, targets: []});
      const target = newTarget(message.params.url);
      if (message.params.newWindow) {
        windows.push({
          id: Math.max(...windows.map(window => window.id)) + 1,
          targets: [target],
        });
      } else {
        windows[windows.length - 1].targets.push(target);
      }
      persist();
      result = {targetId: target.targetId};
      break;
    }
    case "Browser.getWindowForTarget": {
      const target = findTarget(message.params.targetId);
      if (!target) throw new Error("unknown target");
      result = {windowId: target.window.id, bounds: {windowState: "normal"}};
      break;
    }
    case "Browser.close":
      persist();
      send({id: message.id, result: {}});
      process.nextTick(() => process.exit(0));
      return;
    default:
      send({id: message.id, error: {code: -32601,
        message: \`unknown method \${message.method}\`}});
      return;
  }
  send({id: message.id, result});
};
input.on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const boundary = buffer.indexOf(0);
    if (boundary < 0) break;
    const raw = buffer.subarray(0, boundary);
    buffer = buffer.subarray(boundary + 1);
    if (raw.length > 0) handle(JSON.parse(raw));
  }
});
`);
  fs.chmodSync(file, 0o700);
}

function runtimeCommon(browser, browserHash, profile, evidence, key) {
  return [
    "--browser", browser,
    "--browser-sha256", browserHash,
    "--package-id", "desktop",
    "--display-mode", "headless",
    "--profile-dir", profile,
    "--source-device", "d",
    "--profile", "default",
    "--evidence-dir", evidence,
    "--signing-key", key,
    "--timeout-seconds", "5",
  ];
}

test("runtime proof source is observation-only and fail-closed", () => {
  const runner = fs.readFileSync(runtime, "utf8");
  const emitter = fs.readFileSync(status, "utf8");
  assert.match(runner, /"--remote-debugging-pipe"/);
  assert.doesNotMatch(runner, /remote-debugging-port|Network\.setCookie|CookieManager|PasswordStore|HeliumSyncClient|Latest\(|Push\(/);
  assert.match(runner, /packageID === "computer\.helium\.sync\.test"/);
  assert.doesNotMatch(runner, /computer\.helium\.sync["']/);
  assert.match(runner, /--helium-restore-disposable-tabs=/);
  assert.match(emitter,
    /mechanism === "chromium-native-session" \? 1 : 2/);
  assert.match(emitter, /destinations\.size !== 2/);
  assert.match(emitter, /readAuthenticatedEvidence/);
});

test("three runtime mechanisms emit health only from authenticated drills",
  {timeout: 120_000}, () => {
    const runtimeDirectory = process.env.XDG_RUNTIME_DIR;
    const temporaryBase = runtimeDirectory &&
      path.isAbsolute(runtimeDirectory) &&
      fs.existsSync(runtimeDirectory) &&
      (fs.statSync(runtimeDirectory).mode & 0o077) === 0
      ? runtimeDirectory
      : os.tmpdir();
    const temporary = fs.mkdtempSync(
      path.join(temporaryBase, "helium-tab-runtime-proof."));
    fs.chmodSync(temporary, 0o700);
    try {
      const browser = path.join(temporary, "fake-helium");
      writeFakeBrowser(browser);
      const browserHash = sha256File(browser);
      const evidenceRoot = path.join(temporary, "evidence");
      const statusRoot = path.join(temporary, "status");
      run("node", [status, "init-evidence-root",
        "--evidence-root", evidenceRoot]);
      run("node", [status, "init-status-root",
        "--status-root", statusRoot]);
      const key = path.join(evidenceRoot, "runtime-proof.key");
      run("node", [status, "init-key", "--key", key]);

      const nativeRoot = path.join(temporary, "native-root");
      fs.mkdirSync(nativeRoot, {mode: 0o700});
      writePrivate(path.join(nativeRoot,
        ".helium-tab-runtime-proof-root-v1"),
      "helium-tab-runtime-proof-root-v1\n");
      const nativeProfile = path.join(nativeRoot, "drill-native");
      const nativeEvidence = path.join(evidenceRoot, "proof-native");
      run("node", [runtime, "native",
        ...runtimeCommon(browser, browserHash, nativeProfile, nativeEvidence,
          key)]);
      run("node", [status, "verify", "--key", key,
        "--evidence-dir", nativeEvidence]);
      run("node", [status, "emit", "--key", key,
        "--status-root", statusRoot, "--source-device", "d",
        "--profile", "default", "--evidence-dir", nativeEvidence]);

      const heliumTabs = path.join(temporary, "helium-tabs");
      execFileSync("go", ["build", "-o", heliumTabs, "./cmd/helium-tabs"], {
        cwd: repo,
        env: {...process.env, TMPDIR: temporaryBase},
        stdio: "pipe",
      });
      const neutralInput = path.join(temporary, "neutral.json");
      writePrivate(neutralInput, `${JSON.stringify({
        schema_version: 2,
        windows: [
          {
            id: "window-a",
            active_index: 0,
            groups: [],
            tabs: [
              {
                id: "tab-a",
                pinned: true,
                group: "",
                history_state: "bounded",
                current_index: 0,
                navigations: [{
                  url: "https://alpha.fixture.invalid/",
                  title: "alpha",
                }],
              },
              {
                id: "tab-b",
                pinned: false,
                group: "",
                history_state: "bounded",
                current_index: 0,
                navigations: [{
                  url: "https://bravo.fixture.invalid/",
                  title: "bravo",
                }],
              },
            ],
          },
          {
            id: "window-b",
            active_index: 0,
            groups: [],
            tabs: [{
              id: "tab-c",
              pinned: false,
              group: "",
              history_state: "bounded",
              current_index: 0,
              navigations: [{
                url: "https://charlie.fixture.invalid/",
                title: "charlie",
              }],
            }],
          },
        ],
      }, null, 2)}\n`);
      const store = path.join(temporary, "neutral-store");
      fs.mkdirSync(store, {mode: 0o700});
      const captured = JSON.parse(run(heliumTabs, [
        "capture", "--store", store, "--input", neutralInput,
        "--device", "d", "--profile", "default",
        "--browser-version", "fixture", "--chromium-version", "fixture",
        "--reason", "runtime-proof",
      ]));
      const neutralEvidences = [];
      const neutralArchiveHash = crypto.createHash("sha256")
        .update("one archived neutral generation").digest("hex");
      const neutralManifestHash = crypto.createHash("sha256")
        .update("one neutral backup manifest").digest("hex");
      for (const [index, destination] of
        ["nas-on-lm", "da-copy"].entries()) {
        const restored = path.join(temporary, `neutral-restore-${index}`);
        run(heliumTabs, [
          "restore", "--store", store,
          "--generation", captured.generation,
          "--destination", restored,
        ]);
        const root = path.join(temporary, `neutral-root-${index}`);
        fs.mkdirSync(root, {mode: 0o700});
        writePrivate(path.join(root, ".helium-tabs-disposable-root-v1"),
          "helium-tabs-disposable-root-v1\n");
        const prepared = JSON.parse(run(heliumTabs, [
          "prepare-browser-profile", "--restore", restored,
          "--disposable-root", root, "--profile", `drill-neutral-${index}`,
        ]));
        const evidence = path.join(evidenceRoot, `proof-neutral-${index}`);
        const sourceReceipt = path.join(temporary,
          `neutral-source-${index}.env`);
        writePrivate(sourceReceipt, [
          "schema_version=1",
          "mechanism=neutral-topology",
          "source_device=d",
          "profile=default",
          `generation=${captured.generation}`,
          `source_destination=${destination}`,
          `archive_sha256=${neutralArchiveHash}`,
          `backup_manifest_sha256=${neutralManifestHash}`,
          `restore_session_sha256=${captured.files["session.json"].sha256}`,
          "restored_at=2026-07-23T00:00:00Z",
          "",
        ].join("\n"));
        run("node", [runtime, "neutral",
          ...runtimeCommon(browser, browserHash, prepared.destination, evidence,
            key),
          "--helium-tabs", heliumTabs,
          "--source-receipt", sourceReceipt,
        ]);
        neutralEvidences.push(evidence);
      }
      const oneNeutral = failRun("node", [status, "emit",
        "--key", key, "--status-root", statusRoot,
        "--source-device", "d", "--profile", "default",
        "--evidence-dir", neutralEvidences[0]]);
      assert.match(oneNeutral.stderr, /requires exactly 2 evidence directories/);
      run("node", [status, "emit",
        "--key", key, "--status-root", statusRoot,
        "--source-device", "d", "--profile", "default",
        "--evidence-dir", neutralEvidences[0],
        "--evidence-dir", neutralEvidences[1]]);

      const fullEvidences = [];
      const archiveHash = crypto.createHash("sha256")
        .update("one archived full-profile generation").digest("hex");
      for (const [index, destination] of
        ["nas-on-lm", "da-copy"].entries()) {
        const root = path.join(temporary, `full-root-${index}`);
        fs.mkdirSync(root, {mode: 0o700});
        writePrivate(path.join(root, ".helium-disposable-profile-restore-root"),
          "");
        const restored = path.join(root, `drill-full-${index}`);
        fs.cpSync(nativeProfile, restored, {recursive: true});
        fs.chmodSync(restored, 0o700);
        writePrivate(path.join(restored,
          ".helium-profile-restore-receipt.env"), [
          "schema_version=3",
          "generation=full-profile-fixture-v1",
          "source_device=d",
          "profile_id=default",
          `archive_sha256=${archiveHash}`,
          `source_destination=${destination}`,
          "restored_at=2026-07-23T00:00:00Z",
          "",
        ].join("\n"));
        const evidence = path.join(evidenceRoot, `proof-full-${index}`);
        run("node", [runtime, "full-profile",
          ...runtimeCommon(browser, browserHash, restored, evidence, key),
          "--expected-evidence", nativeEvidence,
        ]);
        fullEvidences.push(evidence);
      }
      run("node", [status, "emit",
        "--key", key, "--status-root", statusRoot,
        "--source-device", "d", "--profile", "default",
        "--evidence-dir", fullEvidences[0],
        "--evidence-dir", fullEvidences[1]]);

      const report = JSON.parse(run(health, [statusRoot, "d", "default"]));
      assert.equal(report.healthy, true);
      assert.deepEqual(report.mechanisms.map(item => item.mechanism), [
        "chromium-native-session",
        "neutral-topology",
        "full-profile",
      ]);

      const tampered = path.join(evidenceRoot, "proof-tampered");
      fs.cpSync(nativeEvidence, tampered, {recursive: true});
      fs.chmodSync(tampered, 0o700);
      for (const entry of fs.readdirSync(tampered)) {
        fs.chmodSync(path.join(tampered, entry), 0o600);
      }
      const evidenceFile = path.join(tampered, "evidence.json");
      const parsed = JSON.parse(fs.readFileSync(evidenceFile, "utf8"));
      parsed.generation = "forged";
      writePrivate(evidenceFile, `${JSON.stringify(parsed, null, 2)}\n`);
      const rejected = failRun("node", [status, "verify",
        "--key", key, "--evidence-dir", tampered]);
      assert.match(rejected.stderr, /authentication failed/);

      const androidRejected = failRun("node", [runtime, "native",
        "--browser", "/does/not/exist",
        "--browser-sha256", "0".repeat(64),
        "--package-id", "computer.helium.sync.test",
        "--display-mode", "headless",
        "--profile-dir", path.join(temporary, "unused", "drill-android"),
        "--source-device", "oneplus",
        "--profile", "default",
        "--evidence-dir", path.join(evidenceRoot, "proof-android"),
        "--signing-key", key,
      ]);
      assert.match(androidRejected.stderr,
        /Android adapter unavailable.*no package or profile was touched/);

      const unmarked = path.join(temporary, "unmarked");
      fs.mkdirSync(unmarked, {mode: 0o700});
      const normalRejected = failRun("node", [runtime, "native",
        ...runtimeCommon(browser, browserHash,
          path.join(unmarked, "drill-forbidden"),
          path.join(evidenceRoot, "proof-forbidden"), key),
      ]);
      assert.match(normalRejected.stderr, /marker/);
      assert.equal(fs.existsSync(path.join(unmarked, "drill-forbidden")),
        false);
    } finally {
      fs.rmSync(temporary, {recursive: true, force: true});
    }
  });
