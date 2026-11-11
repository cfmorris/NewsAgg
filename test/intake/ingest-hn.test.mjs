import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { API } from "../../bin/fetch-hn.mjs";
import { main } from "../../bin/ingest-hn.mjs";
import { extractArticle } from "../../lib/ingest/extract.mjs";
import { assertPublicUrl } from "../../lib/ingest/safe-fetch.mjs";

const fixtures = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "ingest");
const archive = JSON.parse(readFileSync(join(fixtures, "archive.json"), "utf8"));
const items = JSON.parse(readFileSync(join(fixtures, "items.json"), "utf8"));
const page = readFileSync(join(fixtures, "article.html"), "utf8");
const ARCHIVE_URL = "https://archive.test/articles";

function capture() {
  return { text: "", write(chunk) { this.text += chunk; } };
}

function hnFetch({ archiveRows = archive } = {}) {
  return async url => {
    if (url === `${API}/newstories.json`) {
      return { ok: true, status: 200, json: async () => [2001, 2002, 2003] };
    }
    if (url === ARCHIVE_URL) {
      return { ok: true, status: 200, json: async () => structuredClone(archiveRows) };
    }
    const match = /\/item\/(\d+)\.json$/.exec(url);
    if (match && items[match[1]]) {
      return { ok: true, status: 200, json: async () => structuredClone(items[match[1]]) };
    }
    throw new Error(`Unexpected fetch: ${url}`);
  };
}

function provider(env = {}) {
  return {
    NEWSAGG_SUMMARY_PROVIDER: "deepseek",
    DEEPSEEK_API_KEY: "test-secret-key",
    DEEPSEEK_BASE_URL: "https://llm.example/api/",
    DEEPSEEK_MODEL: "deepseek-chat",
    ...env
  };
}

test("batch keeps one failed story for retry and skips archived work", async () => {
  const directory = mkdtempSync(join(tmpdir(), "newsagg-ingest-"));
  const retryPath = join(directory, "retry.json");
  try {
    let modelCalls = 0;
    let importerCalls = 0;
    let allowBroken = false;
    const imported = [];

    const llmFetch = async (url, options) => {
      modelCalls += 1;
      assert.equal(url, "https://llm.example/api/chat/completions");
      assert.equal(options.headers.authorization, "Bearer test-secret-key");
      const payload = JSON.parse(options.body);
      assert.match(payload.messages[0].content, /untrusted data/);
      assert.doesNotMatch(payload.messages[0].content, /Prompt Injection/);
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{
            message: {
              content: JSON.stringify({
                summary: "The fixture article describes a public fetch and summarization batch. " +
                  "It extracts publisher metadata before asking the configured model for a summary. " +
                  "Failed stories are kept in a retry file for the next run.",
                depth: "Technical analysis",
                topics: ["Software Engineering", "Prompt Injection"]
              })
            }
          }]
        })
      };
    };

    const fetchArticle = async value => {
      if (value.includes("broken.example") && !allowBroken) {
        throw new Error("Article returned HTTP 503");
      }
      return extractArticle(page, new URL(value));
    };

    const importer = async records => {
      importerCalls += 1;
      imported.push(...records);
      return { stdout: "Imported fixture records\n" };
    };

    const firstOut = capture();
    const firstErr = capture();
    const firstCode = await main(
      ["--limit", "5", "--archive", ARCHIVE_URL, "--retry-file", retryPath],
      {
        env: provider(),
        fetchImpl: hnFetch(),
        llmFetch,
        fetchArticle,
        importer,
        stdout: firstOut,
        stderr: firstErr,
        now: () => new Date("2026-11-11T12:00:00Z")
      }
    );

    assert.equal(firstCode, 1);
    const firstRecords = JSON.parse(firstOut.text);
    assert.equal(firstRecords.length, 1);
    assert.equal(firstRecords[0].external_id, "2002");
    assert.equal(firstRecords[0].url, "https://news.example/story");
    assert.equal(firstRecords[0].publisher, "Evil & Co Publishers");
    assert.deepEqual(firstRecords[0].topics, ["Software Engineering"]);
    assert.equal(firstRecords[0].published_date, "2026-11-09");
    assert.equal(importerCalls, 1);
    assert.equal(modelCalls, 1, "archived and failed fetches must not call the model");

    const retry = JSON.parse(readFileSync(retryPath, "utf8"));
    assert.equal(retry.length, 1);
    assert.equal(retry[0].story.external_id, "2003");
    assert.equal(retry[0].attempts, 1);
    assert.match(retry[0].reason, /HTTP 503/);
    assert.doesNotMatch(firstErr.text, /test-secret-key/);

    allowBroken = true;
    const secondOut = capture();
    const secondErr = capture();
    const archiveWithRecord = [
      ...archive,
      {
        title: firstRecords[0].title,
        url: firstRecords[0].url,
        discoveries: [{ source: "Hacker News", url: firstRecords[0].discovery_url }]
      }
    ];
    const secondCode = await main(
      ["--limit", "5", "--archive", "-", "--retry-file", retryPath],
      {
        env: provider(),
        fetchImpl: hnFetch(),
        llmFetch,
        fetchArticle,
        importer,
        readStdin: async () => JSON.stringify(archiveWithRecord),
        stdout: secondOut,
        stderr: secondErr,
        now: () => new Date("2026-11-11T12:05:00Z")
      }
    );

    assert.equal(secondCode, 0);
    const secondRecords = JSON.parse(secondOut.text);
    assert.equal(secondRecords.length, 1);
    assert.equal(secondRecords[0].external_id, "2003");
    assert.equal(imported.length, 2);
    assert.deepEqual(JSON.parse(readFileSync(retryPath, "utf8")), []);
    assert.equal(modelCalls, 2);
    assert.doesNotMatch(secondErr.text, /test-secret-key/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("private article destinations are rejected before any request", () => {
  for (const url of [
    "http://127.0.0.1/",
    "http://10.0.0.5/",
    "http://169.254.169.254/latest/meta-data",
    "http://[::1]/",
    "http://localhost/",
    "http://user:pass@example.com/article"
  ]) {
    assert.throws(() => assertPublicUrl(url));
  }
  assert.doesNotThrow(() => assertPublicUrl("https://example.com/article"));
});
