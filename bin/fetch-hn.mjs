import { parseArgs } from "node:util";
import { text } from "node:stream/consumers";
import { pathToFileURL } from "node:url";

export const API = "https://hacker-news.firebaseio.com/v0";
const FEEDS = ["new", "top", "best"];
const DEFAULT_ARCHIVE = "http://127.0.0.1:3000/articles";

class UsageError extends Error {}

function parseOptions(args) {
  const { values } = parseArgs({
    args,
    options: {
      feed: { type: "string", default: "new" },
      limit: { type: "string", default: "10" },
      archive: { type: "string", default: DEFAULT_ARCHIVE }
    }
  });

  const limit = Number(values.limit);
  if (!FEEDS.includes(values.feed) ||
      !Number.isInteger(limit) || limit < 1 || limit > 500) {
    throw new UsageError("Use --feed new|top|best and --limit 1–500.");
  }
  return { feed: values.feed, limit, archive: values.archive };
}

function urlKey(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
    url.hash = "";
    for (const key of [...url.searchParams.keys()]) {
      if (/^utm_/i.test(key)) url.searchParams.delete(key);
    }
    return url.href;
  } catch {
    return null;
  }
}

async function json(url, fetchImpl) {
  const response = await fetchImpl(url, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
}

export async function collectCandidates({
  feed,
  limit,
  archive,
  fetchImpl = globalThis.fetch,
  readStdin = () => text(process.stdin)
}) {
  const [archiveRows, ids] = await Promise.all([
    archive === "-" ? readStdin().then(JSON.parse) : json(archive, fetchImpl),
    json(`${API}/${feed}stories.json`, fetchImpl)
  ]);
  if (!Array.isArray(archiveRows) || !Array.isArray(ids)) {
    throw new Error("Expected article and Hacker News ID arrays.");
  }

  const knownUrls = new Set(archiveRows.map(article => urlKey(article.url)).filter(Boolean));
  const knownDiscussions = new Set(archiveRows.flatMap(article => (article.discoveries || [])
    .filter(discovery => discovery.source === "Hacker News")
    .map(discovery => new URL(discovery.url).searchParams.get("id"))));
  const unseen = [...new Set(ids)].filter(id => Number.isSafeInteger(id) && !knownDiscussions.has(String(id)));
  const stories = [];
  const concurrency = 12;
  for (let offset = 0; offset < unseen.length && stories.length < limit; offset += concurrency) {
    const items = await Promise.all(unseen.slice(offset, offset + concurrency)
      .map(id => json(`${API}/item/${id}.json`, fetchImpl)));
    for (const item of items) {
      if (item?.type !== "story" || item.dead || item.deleted || !item.title) continue;
      const discoveryUrl = `https://news.ycombinator.com/item?id=${item.id}`;
      const key = urlKey(item.url || discoveryUrl);
      if (!key || knownUrls.has(key)) continue;
      knownUrls.add(key);
      stories.push({
        title: item.title,
        url: item.url || discoveryUrl,
        source: "Hacker News",
        external_id: String(item.id),
        discovery_url: discoveryUrl,
        submitted_at: new Date(item.time * 1000).toISOString(),
        score: item.score
      });
      if (stories.length === limit) break;
    }
  }
  return stories;
}

export async function main(args = process.argv.slice(2), {
  fetchImpl = globalThis.fetch,
  readStdin = () => text(process.stdin),
  stdout = process.stdout,
  stderr = process.stderr
} = {}) {
  let options;
  try {
    options = parseOptions(args);
  } catch (error) {
    if (error instanceof UsageError) {
      stderr.write(`${error.message}\n`);
      return 2;
    }
    throw error;
  }

  try {
    const stories = await collectCandidates({ ...options, fetchImpl, readStdin });
    stdout.write(`${JSON.stringify(stories, null, 2)}\n`);
    return 0;
  } catch (error) {
    stderr.write(`Hacker News intake failed: ${error.message}\n`);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
