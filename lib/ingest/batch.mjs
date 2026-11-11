import { archiveKeys, collectCandidates, urlKey } from "../../bin/fetch-hn.mjs";
import { cleanText, sanitizePublisher, sanitizeTitle } from "./extract.mjs";
import { fetchPublicArticle } from "./safe-fetch.mjs";
import { DEPTHS } from "./summarizer.mjs";

const MAX_REASON = 300;

export function redactSecrets(value, secrets = []) {
  let text = String(value ?? "");
  for (const secret of secrets) {
    if (typeof secret === "string" && secret.length >= 4) {
      text = text.split(secret).join("[redacted]");
    }
  }
  return text;
}

export function failureReason(error, secrets = []) {
  const reason = cleanText(redactSecrets(error?.message || String(error), secrets), MAX_REASON);
  return reason || "Unknown ingestion failure";
}

export function storyForRecord(record) {
  return {
    url: record.url,
    title: record.title,
    source: record.source,
    external_id: record.external_id,
    ...(record.discovery_url ? { discovery_url: record.discovery_url } : {})
  };
}

function validRecord(record) {
  if (!record || typeof record !== "object") return null;
  const url = urlKey(record.url);
  const required = ["title", "summary", "depth", "publisher", "source", "external_id"];
  if (!url || required.some(key => typeof record[key] !== "string" || !record[key].trim())) return null;
  if (!DEPTHS.includes(record.depth)) return null;
  if (!Array.isArray(record.topics) || record.topics.length === 0 ||
      record.topics.some(topic => typeof topic !== "string" || !topic.trim())) return null;
  return { ...record, url };
}

function normalizedRetry(entry) {
  if (!entry || typeof entry !== "object") return null;
  const story = entry.story && typeof entry.story === "object" ? entry.story : entry;
  if (!story || typeof story !== "object") return null;
  const key = urlKey(story.url);
  if (!key) return null;
  return {
    story,
    record: entry.record ? validRecord(entry.record) : null,
    attempts: Number.isInteger(entry.attempts) && entry.attempts > 0 ? entry.attempts : 0
  };
}

export async function runBatch({
  feed = "new",
  limit = 10,
  archiveRows = [],
  retryEntries = [],
  fetchImpl = globalThis.fetch,
  fetchArticle = fetchPublicArticle,
  summarize,
  now = () => new Date(),
  secrets = []
} = {}) {
  if (typeof summarize !== "function") throw new Error("A summarizer is required.");

  const archive = archiveKeys(archiveRows);
  const candidates = new Map();
  const skipped = [];

  for (const entry of retryEntries) {
    const retry = normalizedRetry(entry);
    if (!retry) continue;
    const key = urlKey(retry.story.url);
    const externalId = retry.story.external_id == null ? null : String(retry.story.external_id);
    if (archive.knownUrls.has(key) || (externalId && archive.knownDiscussions.has(externalId))) {
      skipped.push(retry.story);
      continue;
    }
    if (!candidates.has(key)) candidates.set(key, retry);
  }

  const fresh = await collectCandidates({ feed, limit, archiveRows, fetchImpl });
  for (const story of fresh) {
    const key = urlKey(story.url);
    if (!key) continue;
    const existing = candidates.get(key);
    if (existing) {
      candidates.set(key, { ...existing, story: { ...existing.story, ...story } });
    } else {
      candidates.set(key, { story, record: null, attempts: 0 });
    }
  }

  const records = [];
  const failures = [];
  const produced = new Set();
  let modelCalls = 0;

  for (const candidate of candidates.values()) {
    const story = candidate.story;
    const key = urlKey(story.url);

    if (candidate.record) {
      if (archive.knownUrls.has(key) || produced.has(key)) {
        skipped.push(story);
        continue;
      }
      produced.add(key);
      records.push(candidate.record);
      continue;
    }

    try {
      if (archive.knownUrls.has(key)) {
        skipped.push(story);
        continue;
      }

      const page = await fetchArticle(story.url);
      const finalUrl = urlKey(page?.finalUrl) || key;
      if (!finalUrl) throw new Error("Article has no usable canonical URL");
      if (archive.knownUrls.has(finalUrl) || produced.has(finalUrl)) {
        skipped.push(story);
        continue;
      }

      const title = sanitizeTitle(story.title);
      if (!title) throw new Error("Story has no usable title");
      const publisher = sanitizePublisher(page?.publisher, new URL(finalUrl).hostname.replace(/^www\./i, ""));
      if (!publisher) throw new Error("Article has no usable publisher");
      if (!page?.text || page.text.length < 40) throw new Error("Article text is too short");

      modelCalls += 1;
      const summary = await summarize({
        url: finalUrl,
        title,
        publisher,
        text: page.text
      });
      const summarized = validRecord({
        url: finalUrl,
        title,
        summary: summary?.summary,
        depth: summary?.depth,
        publisher,
        topics: summary?.topics,
        source: story.source || "Hacker News",
        external_id: String(story.external_id ?? ""),
        ...(story.discovery_url ? { discovery_url: story.discovery_url } : {}),
        ...(page.publishedDate ? { published_date: page.publishedDate } : {})
      });
      if (!summarized) throw new Error("Summary did not match the importer contract");

      produced.add(finalUrl);
      records.push(summarized);
    } catch (error) {
      failures.push({
        story,
        record: null,
        reason: failureReason(error, secrets),
        attempts: candidate.attempts + 1,
        failed_at: now().toISOString()
      });
    }
  }

  return { records, failures, skippedArchived: skipped.length, modelCalls };
}
