const MAX_TEXT = 12_000;
const MAX_PUBLISHER = 120;
const MAX_TITLE = 300;

const NAMED_ENTITIES = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  ndash: "\u2013", mdash: "\u2014", hellip: "\u2026",
  lsquo: "\u2018", rsquo: "\u2019", ldquo: "\u201c", rdquo: "\u201d"
};

const UNSAFE_CHARS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/g;

function codePoint(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 && number <= 0x10ffff &&
    !(number >= 0xd800 && number <= 0xdfff) ? String.fromCodePoint(number) : "";
}

export function decodeEntities(value) {
  return String(value ?? "").replace(/&(?:#(\d+)|#x([0-9a-f]+)|([a-z][a-z0-9]+));/gi,
    (match, decimal, hexadecimal, name) => {
      if (decimal) return codePoint(decimal);
      if (hexadecimal) return codePoint(Number.parseInt(hexadecimal, 16));
      return NAMED_ENTITIES[name.toLowerCase()] ?? match;
    });
}

export function cleanText(value, limit = MAX_TEXT) {
  let text = decodeEntities(value);
  for (let pass = 0; pass < 3 && text.includes("<"); pass += 1) {
    text = text.replace(/<[^>]*>/g, " ");
  }
  text = text.replace(UNSAFE_CHARS, " ").replace(/[<>]/g, " ");
  text = text.replace(/\s+/g, " ").trim();
  return Array.from(text).slice(0, limit).join("").trim();
}

export function sanitizePublisher(value, fallback = "") {
  const text = cleanText(value, MAX_PUBLISHER).replace(/^@+/, "").trim();
  return text || fallback;
}

export function sanitizeTitle(value) {
  return cleanText(value, MAX_TITLE);
}

function parseAttributes(tag) {
  const attributes = {};
  const pattern = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
  let match;
  while ((match = pattern.exec(tag))) {
    attributes[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4] ?? "";
  }
  return attributes;
}

function readMeta(html) {
  const values = new Map();
  for (const match of html.matchAll(/<meta\b[^>]*>/gi)) {
    const attributes = parseAttributes(match[0]);
    const key = (attributes.property || attributes.name || attributes.itemprop || "").toLowerCase();
    if (!key || !attributes.content) continue;
    if (!values.has(key)) values.set(key, attributes.content);
  }
  return values;
}

function walkStructuredData(node, visit) {
  if (Array.isArray(node)) {
    for (const child of node) walkStructuredData(child, visit);
    return;
  }
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const value of Object.values(node)) walkStructuredData(value, visit);
}

function readStructuredData(html) {
  const found = { publisher: "", author: "", published: "" };
  for (const match of html.matchAll(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    let data;
    try {
      data = JSON.parse(decodeEntities(match[1]).trim());
    } catch {
      continue;
    }
    walkStructuredData(data, node => {
      const types = [node["@type"]].flat().filter(Boolean).map(String);
      if (!types.some(type => /article|posting|blog/i.test(type))) return;
      if (!found.publisher) {
        const publisher = node.publisher;
        found.publisher = typeof publisher === "string"
          ? publisher
          : publisher?.name || publisher?.legalName || "";
      }
      if (!found.author) {
        const author = node.author;
        found.author = typeof author === "string"
          ? author
          : (Array.isArray(author) ? author[0]?.name : author?.name) || "";
      }
      if (!found.published && typeof node.datePublished === "string") {
        found.published = node.datePublished;
      }
    });
  }
  return found;
}

function htmlToText(html) {
  const preferred = /<(article|main)\b[^>]*>([\s\S]*?)<\/\1>/i.exec(html);
  let body = preferred ? preferred[2] : html;
  body = body.replace(/<(script|style|noscript|template|svg|iframe|object)\b[^>]*>[\s\S]*?<\/\1>/gi, " ");
  body = body.replace(/<!--[\s\S]*?-->/g, " ");
  body = body.replace(/<\/(p|div|li|h[1-6]|tr|section|article|main|blockquote)>/gi, "\n");
  body = body.replace(/<br\s*\/?>/gi, "\n");
  body = body.replace(/<[^>]*>/g, " ");
  return decodeEntities(body).replace(/\s+/g, " ").trim();
}

function publishedDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value || "").trim());
  if (!match) return null;
  const [year, month, day] = match.slice(1).map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) {
    return null;
  }
  return `${match[1]}-${match[2]}-${match[3]}`;
}

export function extractArticle(html, url, { contentType = "text/html" } = {}) {
  const source = String(html ?? "");
  const fallbackPublisher = url.hostname.replace(/^www\./i, "");
  if (/^text\/plain\b/i.test(contentType)) {
    return {
      finalUrl: url.href,
      title: "",
      publisher: sanitizePublisher("", fallbackPublisher),
      text: cleanText(source),
      publishedDate: null
    };
  }

  const meta = readMeta(source);
  const structured = readStructuredData(source);
  const rawPublisher = meta.get("og:site_name") || structured.publisher ||
    meta.get("application-name") || meta.get("publisher") ||
    meta.get("twitter:site") || structured.author;
  const publisher = sanitizePublisher(rawPublisher, fallbackPublisher);

  let text = cleanText(htmlToText(source));
  if (text.length < 80) {
    const description = meta.get("og:description") || meta.get("description") || "";
    text = cleanText(`${description} ${text}`);
  }

  const published = publishedDate(
    meta.get("article:published_time") || meta.get("datepublished") ||
    meta.get("date") || structured.published
  );

  return {
    finalUrl: url.href,
    title: sanitizeTitle(meta.get("og:title") || ""),
    publisher,
    text,
    publishedDate: published
  };
}

export { MAX_TEXT };
