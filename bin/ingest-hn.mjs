import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { text } from "node:stream/consumers";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

import { DEFAULT_ARCHIVE, loadArchive } from "./fetch-hn.mjs";
import { failureReason, redactSecrets, runBatch, storyForRecord } from "../lib/ingest/batch.mjs";
import { createSummarizer, SummaryError } from "../lib/ingest/summarizer.mjs";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const DEFAULT_RETRY = join(REPO_ROOT, "tmp", "hn-retry.json");

class UsageError extends Error {}

function parseOptions(args) {
  const { values } = parseArgs({
    args,
    options: {
      feed: { type: "string", default: "new" },
      limit: { type: "string", default: "10" },
      archive: { type: "string", default: DEFAULT_ARCHIVE },
      "retry-file": { type: "string" },
      "dry-run": { type: "boolean", default: false },
      help: { type: "boolean", default: false }
    }
  });

  if (values.help) return { help: true };
  const limit = Number(values.limit);
  if (!["new", "top", "best"].includes(values.feed) ||
      !Number.isInteger(limit) || limit < 1 || limit > 500) {
    throw new UsageError("Use --feed new|top|best and --limit 1-500.");
  }
  return {
    feed: values.feed,
    limit,
    archive: values.archive,
    retryFile: resolve(values["retry-file"] || DEFAULT_RETRY),
    dryRun: values["dry-run"]
  };
}

function usage() {
  return [
    "Usage: node bin/ingest-hn.mjs [--feed new|top|best] [--limit N]",
    "       [--archive URL|-] [--retry-file PATH] [--dry-run]",
    "       [--watch] (check every 60 seconds when Auto-pull is on)",
    "",
    "Provider configuration (required):",
    "  NEWSAGG_SUMMARY_PROVIDER=deepseek",
    "  DEEPSEEK_API_KEY=<key>",
    "Optional: DEEPSEEK_BASE_URL, DEEPSEEK_MODEL, NEWSAGG_SUMMARY_TIMEOUT_MS",
    "Importer: NEWSAGG_RUBY (default: ruby) plus the existing NEO4J_* variables.",
    ""
  ].join("\n");
}

function readRetryEntries(path, read = readFileSync) {
  let raw;
  try {
    raw = read(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw new UsageError("Could not read the retry file.");
  }
  if (!raw.trim()) return [];
  let entries;
  try {
    entries = JSON.parse(raw);
  } catch {
    throw new UsageError("The retry file is not valid JSON.");
  }
  if (!Array.isArray(entries)) throw new UsageError("The retry file must contain an array.");
  return entries;
}

function writeRetryEntries(path, entries) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(entries, null, 2)}\n`, "utf8");
  renameSync(temporary, path);
}

export async function importWithRuby(records, { env = process.env } = {}) {
  return new Promise((resolvePromise, reject) => {
    const ruby = env.NEWSAGG_RUBY || "ruby";
    const child = spawn(ruby, [join(REPO_ROOT, "bin/import-news")], {
      cwd: REPO_ROOT,
      env,
      stdio: ["pipe", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    const limit = 1024 * 1024;
    child.stdout.on("data", chunk => { if (stdout.length < limit) stdout += chunk; });
    child.stderr.on("data", chunk => { if (stderr.length < limit) stderr += chunk; });
    child.stdin.on("error", () => {});
    child.on("error", error => {
      reject(new Error(error?.code === "ENOENT"
        ? "Ruby executable not found. Set NEWSAGG_RUBY or add Ruby to PATH."
        : "Could not start the Neo4j importer."));
    });
    child.on("close", code => {
      if (code === 0) return resolvePromise({ stdout, stderr });
      const detail = redactSecrets(stderr, [env.NEO4J_PASSWORD, env.DEEPSEEK_API_KEY])
        .replace(/\s+/g, " ").trim().slice(0, 500);
      reject(new Error(`Importer exited with code ${code}${detail ? `: ${detail}` : ""}`));
    });
    child.stdin.end(JSON.stringify(records));
  });
}

export async function main(args = process.argv.slice(2), {
  env = process.env,
  fetchImpl = globalThis.fetch,
  llmFetch,
  readStdin = () => text(process.stdin),
  fetchArticle,
  summarize,
  importer = importWithRuby,
  stdout = process.stdout,
  stderr = process.stderr,
  now = () => new Date(),
  readRetry = readFileSync,
  writeRetry = writeRetryEntries
} = {}) {
  let options;
  try {
    options = parseOptions(args);
  } catch (error) {
    stderr.write(`${error instanceof UsageError ? error.message : "Invalid arguments."}\n`);
    return 2;
  }
  if (options.help) {
    stdout.write(usage());
    return 0;
  }

  const secrets = [env.DEEPSEEK_API_KEY, env.NEO4J_PASSWORD];
  try {
    const archiveRows = await loadArchive({
      archive: options.archive,
      fetchImpl,
      readStdin
    });
    const retryEntries = readRetryEntries(options.retryFile, readRetry);

    let runSummarize = summarize;
    if (!runSummarize) {
      runSummarize = createSummarizer({ env, fetchImpl: llmFetch || globalThis.fetch });
    }

    const result = await runBatch({
      feed: options.feed,
      limit: options.limit,
      archiveRows,
      retryEntries,
      fetchImpl,
      ...(fetchArticle ? { fetchArticle } : {}),
      summarize: runSummarize,
      now,
      secrets
    });

    let importFailures = [];
    if (result.records.length > 0 && !options.dryRun) {
      try {
        const imported = await importer(result.records, { env });
        if (imported?.stdout) {
          stderr.write(`${redactSecrets(cleanLine(imported.stdout), secrets)}\n`);
        }
      } catch (error) {
        const reason = `import failed: ${failureReason(error, secrets)}`;
        importFailures = result.records.map(record => ({
          story: storyForRecord(record),
          record,
          reason,
          attempts: 1,
          failed_at: now().toISOString()
        }));
      }
    }

    const failures = [...result.failures, ...importFailures];
    if (!options.dryRun) writeRetry(options.retryFile, failures);

    stdout.write(`${JSON.stringify(result.records, null, 2)}\n`);
    stderr.write(
      `Hacker News batch: ${result.records.length} record(s), ` +
      `${result.skippedArchived} already archived, ${failures.length} kept for retry.\n`
    );
    return failures.length === 0 ? 0 : 1;
  } catch (error) {
    if (error instanceof SummaryError || error instanceof UsageError) {
      stderr.write(`${error.message}\n`);
      return 2;
    }
    stderr.write(`Hacker News batch failed: ${failureReason(error, secrets)}\n`);
    return 1;
  }
}

function cleanLine(value) {
  return String(value).replace(/\s+/g, " ").trim().slice(0, 500);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (!args.includes("--watch")) {
    process.exitCode = await main(args);
  } else if ((args.includes("--archive") && args[args.indexOf("--archive") + 1] === "-") ||
             args.includes("--archive=-")) {
    console.error("Watch mode needs a dashboard URL so it can reread the archive each time.");
    process.exitCode = 2;
  } else {
    const batchArgs = args.filter(arg => arg !== "--watch");
    if (batchArgs.includes("--help")) {
      process.exitCode = await main(batchArgs);
    } else {
      const flag = join(REPO_ROOT, "tmp", "auto-pull.enabled");
      do {
        const started = performance.now();
        if (existsSync(flag)) {
          process.exitCode = await main(batchArgs);
          if (process.exitCode === 2) break;
        }
        await delay(Math.max(0, 60_000 - (performance.now() - started)));
      } while (true);
    }
  }
}
