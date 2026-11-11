import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  API,
  collectCandidates,
  main
} from "../../bin/fetch-hn.mjs";

const fixtures = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const archive = JSON.parse(readFileSync(join(fixtures, "archive.json"), "utf8"));
const items = JSON.parse(readFileSync(join(fixtures, "items.json"), "utf8"));
const ARCHIVE_URL = "https://archive.test/articles";

function fakeFetch({ ids = [], failures = [] } = {}) {
  const calls = [];
  const failing = new Set(failures);
  const impl = async (url) => {
    calls.push(url);
    if (failing.has("*") || failing.has(url)) {
      return { ok: false, status: 500, json: async () => ({}) };
    }
    if (url === `${API}/newstories.json`) {
      return { ok: true, status: 200, json: async () => structuredClone(ids) };
    }
    if (url === ARCHIVE_URL) {
      return { ok: true, status: 200, json: async () => structuredClone(archive) };
    }
    const item = /^https:\/\/hacker-news\.firebaseio\.com\/v0\/item\/(\d+)\.json$/.exec(url);
    if (item && items[item[1]]) {
      return { ok: true, status: 200, json: async () => structuredClone(items[item[1]]) };
    }
    throw new Error(`Unexpected fetch: ${url}`);
  };
  return { impl, calls };
}

function collect(ids, limit = 500, extra = {}) {
  const fake = fakeFetch({ ids, ...extra });
  return collectCandidates({
    feed: "new",
    limit,
    archive: ARCHIVE_URL,
    fetchImpl: fake.impl
  }).then(stories => ({ stories, calls: fake.calls }));
}

function capture() {
  return {
    text: "",
    write(chunk) { this.text += chunk; }
  };
}

test("skips stories already archived by Hacker News discussion id", async () => {
  const { stories, calls } = await collect([1001]);
  assert.deepEqual(stories, []);
  assert.ok(!calls.some(url => url.includes("/item/1001.json")),
    "archived discussion ids should not be fetched again");
});

test("skips stories whose URL matches the archive after normalization", async () => {
  const { stories, calls } = await collect([1002]);
  assert.deepEqual(stories, []);
  assert.ok(calls.includes(`${API}/item/1002.json`),
    "the item is fetched before its URL can be compared");
});

test("excludes dead, deleted, non-story, untitled, and unsupported items", async () => {
  const { stories } = await collect([1003, 1004, 1005, 1006, 1010]);
  assert.deepEqual(stories, []);
});

test("deduplicates normalized URLs within one run", async () => {
  const { stories } = await collect([1007, 1008]);
  assert.equal(stories.length, 1);
  assert.equal(stories[0].external_id, "1007");
  assert.equal(stories[0].url, "https://example.com/fresh?utm_campaign=launch#top");
});

test("stops at the requested limit without reordering candidates", async () => {
  const { stories } = await collect([1007, 1009], 1);
  assert.deepEqual(stories.map(story => story.external_id), ["1007"]);

  const both = await collectCandidates({
    feed: "new",
    limit: 2,
    archive: ARCHIVE_URL,
    fetchImpl: fakeFetch({ ids: [1007, 1009] }).impl
  });
  assert.deepEqual(both.map(story => story.external_id), ["1007", "1009"]);
});

test("uses the discussion URL for self posts", async () => {
  const { stories } = await collect([1009]);
  assert.equal(stories.length, 1);
  assert.equal(stories[0].url, "https://news.ycombinator.com/item?id=1009");
  assert.equal(stories[0].discovery_url, "https://news.ycombinator.com/item?id=1009");
  assert.equal(stories[0].source, "Hacker News");
  assert.equal(stories[0].title, "Ask HN: A self post");
  assert.equal(stories[0].submitted_at, new Date(1762800480 * 1000).toISOString());
  assert.equal(stories[0].score, 22);
});

test("main prints JSON and returns 0 for a successful run", async () => {
  const fake = fakeFetch({ ids: [1007] });
  const stdout = capture();
  const stderr = capture();
  const code = await main(["--limit", "1", "--archive", ARCHIVE_URL], {
    fetchImpl: fake.impl,
    stdout,
    stderr
  });
  assert.equal(code, 0);
  assert.equal(stderr.text, "");
  const stories = JSON.parse(stdout.text);
  assert.equal(stories.length, 1);
  assert.equal(stories[0].external_id, "1007");
});

test("main reads the existing archive from stdin without contacting it", async () => {
  const fake = fakeFetch({ ids: [1001] });
  const stdout = capture();
  const code = await main(["--archive", "-"], {
    fetchImpl: fake.impl,
    readStdin: async () => JSON.stringify(archive),
    stdout,
    stderr: capture()
  });
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(stdout.text), []);
});

test("main reports intake failures with exit code 1", async () => {
  const fake = fakeFetch({ ids: [1007], failures: [`${API}/newstories.json`] });
  const stderr = capture();
  const code = await main(["--archive", ARCHIVE_URL], {
    fetchImpl: fake.impl,
    stdout: capture(),
    stderr
  });
  assert.equal(code, 1);
  assert.match(stderr.text, /^Hacker News intake failed: .*newstories\.json returned HTTP 500/);
});
