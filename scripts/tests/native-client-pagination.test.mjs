import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync(new URL(
  "../../chromium/overlay/components/helium_sync/helium_sync_client.cc",
  import.meta.url,
), "utf8");

const functionBody = (signature, nextSignature) => source.slice(
  source.indexOf(signature),
  source.indexOf(nextSignature, source.indexOf(signature)),
);

test("pull and latest use the strict paginated request contract", () => {
  const path = functionBody("std::string RecordsPath", "} // namespace");
  assert.match(path, /append_param\("limit", base::NumberToString\(kRecordsPageSize\)\)/);
  assert.match(path, /if \(since\)[\s\S]*append_param\("since"/);
  assert.match(path, /if \(!cursor\.empty\(\)\)[\s\S]*append_param\("cursor"/);
  assert.match(path, /for \(const auto &kind : kinds\)[\s\S]*append_param\("kind"/);

  const pull = functionBody("void HeliumSyncClient::Pull", "void HeliumSyncClient::Latest");
  assert.match(pull, /pagination->since = since/);
  assert.match(pull, /FetchRecordsPage/);

  const latest = functionBody(
    "void HeliumSyncClient::Latest",
    "bool HeliumSyncClient::AcknowledgeApplied",
  );
  assert.doesNotMatch(latest, /pagination->since/);
  assert.match(latest, /FetchRecordsPage/);

  const fetch = functionBody(
    "void HeliumSyncClient::FetchRecordsPage",
    "void HeliumSyncClient::OnRecordsPageComplete",
  );
  assert.match(fetch, /pagination->cursor\.empty\(\) \? pagination->since : std::nullopt/);
});

test("page responses require versioned metadata without changing push", () => {
  const parsePage = functionBody(
    "HeliumSyncClient::ParseRecordsPageResponse",
    "void HeliumSyncClient::FetchRecordsPage",
  );
  assert.match(parsePage, /FindString\("page_cursor"\)/);
  assert.match(parsePage, /FindInt\("page_version"\)\.value_or\(0\) != 1/);
  assert.match(parsePage, /ParseRecordsObject/);

  const push = functionBody(
    "void HeliumSyncClient::OnPushComplete",
    "void HeliumSyncClient::OnEnrollmentComplete",
  );
  assert.match(push, /ParseRecordsResponse/);
  assert.doesNotMatch(push, /ParseRecordsPageResponse|page_cursor|page_version/);
});

test("pagination aggregates one immutable ordered snapshot within hard bounds", () => {
  assert.match(source, /constexpr size_t kRecordsPageSize = 128/);
  assert.match(source, /constexpr size_t kMaxRecordsPages = 512/);
  assert.match(source, /constexpr size_t kMaxRecordsPerSync =/);
  assert.match(source, /constexpr size_t kMaxAggregateResponseBytes = 128 \* 1024 \* 1024/);

  const complete = functionBody(
    "void HeliumSyncClient::OnRecordsPageComplete",
    "void HeliumSyncClient::OnPushComplete",
  );
  assert.match(complete, /page->next_seq != \*pagination->next_seq/);
  assert.match(complete, /record\.seq <= previous_seq/);
  assert.match(complete, /record\.seq > \*pagination->next_seq/);
  assert.match(complete, /record\.seq <= \*pagination->since/);
  assert.match(complete, /kMaxRecordsPerSync - pagination->records\.size\(\)/);
  assert.match(complete, /kMaxAggregateResponseBytes - pagination->aggregate_response_bytes/);
  assert.match(complete, /pagination->aggregate_response_bytes \+= body->size\(\)/);
  assert.match(complete, /pagination->seen_cursors/);

  const chargeBytes = complete.indexOf(
    "pagination->aggregate_response_bytes += body->size()",
  );
  const parsePage = complete.indexOf("ParseRecordsPageResponse");
  const appendRecord = complete.indexOf("pagination->records.push_back");
  assert.ok(chargeBytes >= 0 && parsePage > chargeBytes && appendRecord > parsePage);

  const finish = complete.indexOf("if (page_cursor.empty())");
  const callback = complete.indexOf("callback).Run(true", finish);
  const continuePaging = complete.lastIndexOf("FetchRecordsPage");
  assert.ok(finish >= 0 && callback > finish && continuePaging > callback);
});
