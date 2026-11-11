import { parseArgs } from "node:util";
import { text } from "node:stream/consumers";

const api = "https://hacker-news.firebaseio.com/v0";
const { values } = parseArgs({
  options: {
    feed: { type: "string", default: "new" },
    limit: { type: "string", default: "10" },
    archive: { type: "string", default: "http://127.0.0.1:3000/articles" }
  }
});

const limit = Number(values.limit);
if (!["new", "top", "best"].includes(values.feed) ||
    !Number.isInteger(limit) || limit < 1 || limit > 500) {
  console.error("Use --feed new|top|best and --limit 1–500.");
  process.exit(2);
}

async function json(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
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

async function candidates() {
  const [archive, ids] = await Promise.all([
    values.archive === "-" ? text(process.stdin).then(JSON.parse) : json(values.archive),
    json(`${api}/${values.feed}stories.json`)
  ]);
  if (!Array.isArray(archive) || !Array.isArray(ids)) {
    throw new Error("Expected article and Hacker News ID arrays.");
  }

  const knownUrls = new Set(archive.map(article => urlKey(article.url)).filter(Boolean));
  const knownDiscussions = new Set(archive.flatMap(article => (article.discoveries || [])
    .filter(discovery => discovery.source === "Hacker News")
    .map(discovery => new URL(discovery.url).searchParams.get("id"))));
  const unseen = [...new Set(ids)].filter(id => Number.isSafeInteger(id) && !knownDiscussions.has(String(id)));
  const stories = [];
  const concurrency = 12;
  for (let offset = 0; offset < unseen.length && stories.length < limit; offset += concurrency) {
    const items = await Promise.all(unseen.slice(offset, offset + concurrency)
      .map(id => json(`${api}/item/${id}.json`)));
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

try {
  const stories = await candidates();
  console.log(JSON.stringify(stories, null, 2));
} catch (error) {
  console.error(`Hacker News intake failed: ${error.message}`);
  process.exitCode = 1;
}
