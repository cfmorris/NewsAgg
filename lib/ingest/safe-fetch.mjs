import dns from "node:dns";
import http from "node:http";
import https from "node:https";
import net from "node:net";

export class FetchError extends Error {
  constructor(message) {
    super(message);
    this.name = "FetchError";
  }
}

export const FETCH_LIMITS = Object.freeze({
  timeoutMs: 10_000,
  lookupTimeoutMs: 5_000,
  maxRedirects: 5,
  maxBodyBytes: 2 * 1024 * 1024
});

const USER_AGENT = "NewsAgg-ingestion/1.0";
const REDIRECT_CODES = new Set([301, 302, 303, 307, 308]);
const HTML_TYPE = /^(?:text\/html|application\/xhtml\+xml)\b/i;

function bareHostname(hostname) {
  return hostname.startsWith("[") && hostname.endsWith("]")
    ? hostname.slice(1, -1)
    : hostname;
}

function ipv4IsPrivate(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some(part => !Number.isInteger(part) || part < 0 || part > 255)) {
    return true;
  }
  const [a, b, c] = parts;
  if (a === 0 || a === 10 || a === 127 || a >= 224) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 0 && (c === 0 || c === 2)) return true;
  if (a === 192 && b === 88 && c === 99) return true;
  if (a === 192 && b === 168) return true;
  if (a === 198 && (b === 18 || b === 19)) return true;
  if (a === 198 && b === 51 && c === 100) return true;
  if (a === 203 && b === 0 && c === 113) return true;
  return false;
}

function ipv6IsPrivate(address) {
  const value = address.toLowerCase().split("%")[0];

  const dotted = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(value);
  if (dotted) return ipv4IsPrivate(dotted[1]);

  const mapped = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(value);
  if (mapped) {
    const high = Number.parseInt(mapped[1], 16);
    const low = Number.parseInt(mapped[2], 16);
    return ipv4IsPrivate([high >> 8, high & 0xff, low >> 8, low & 0xff].join("."));
  }

  // Only global unicast (2000::/3) is acceptable. That excludes loopback,
  // unspecified, IPv4-compatible/mapped forms, ULA, link-local and multicast.
  const first = Number.parseInt(value.split(":")[0] || "0", 16);
  if (!Number.isInteger(first) || first < 0x2000 || first > 0x3fff) return true;
  if (value === "2001:db8" || value.startsWith("2001:db8:")) return true;
  if (value === "2002" || value.startsWith("2002:")) return true;
  if (value === "3fff" || value.startsWith("3fff:")) return true;
  // Teredo (2001::/32) and benchmarking (2001:2::/48) can embed other scopes.
  if (value === "2001:0" || value.startsWith("2001:0:") || value.startsWith("2001:2:")) return true;
  return false;
}

export function isPrivateAddress(address) {
  const version = net.isIP(address);
  if (version === 4) return ipv4IsPrivate(address);
  if (version === 6) return ipv6IsPrivate(address);
  return true;
}

export function assertPublicUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new FetchError("Article URL is not valid");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new FetchError("Only public HTTP(S) article URLs are allowed");
  }
  if (url.username || url.password) {
    throw new FetchError("Article URLs must not contain credentials");
  }
  if (!url.hostname) throw new FetchError("Article URL has no host");
  if (url.href.length > 2_048) throw new FetchError("Article URL is too long");

  const host = bareHostname(url.hostname).toLowerCase();
  if (net.isIP(host)) {
    if (isPrivateAddress(host)) {
      throw new FetchError("Article URL points to a private destination");
    }
    return url;
  }
  if (host === "localhost" || host.endsWith(".localhost") ||
      host.endsWith(".local") || host.endsWith(".internal") ||
      host === "home.arpa" || host.endsWith(".home.arpa")) {
    throw new FetchError("Article URL points to a private destination");
  }
  return url;
}

function privateDestinationError() {
  return new FetchError("Article host resolves to a private destination");
}

export function lookupPublicAddress(hostname, _options, callback) {
  const host = bareHostname(hostname);
  if (net.isIP(host)) {
    if (isPrivateAddress(host)) return callback(privateDestinationError());
    return callback(null, host, net.isIP(host));
  }

  let settled = false;
  const finish = (error, address, family) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    callback(error, address, family);
  };
  const timer = setTimeout(() => finish(new FetchError("Timed out resolving article host")),
    FETCH_LIMITS.lookupTimeoutMs);

  dns.lookup(host, { all: true, verbatim: true }, (error, addresses) => {
    if (error) return finish(new FetchError("Could not resolve article host"));
    if (!Array.isArray(addresses) || addresses.length === 0) {
      return finish(privateDestinationError());
    }
    // A mixed public/private answer is treated as hostile so DNS round-robin
    // tricks cannot redirect a later connection into a private network.
    if (addresses.some(({ address }) => isPrivateAddress(address))) {
      return finish(privateDestinationError());
    }
    finish(null, addresses[0].address, addresses[0].family);
  });
}

function requestOnce(url, { deadline, maxBodyBytes }) {
  return new Promise((resolve, reject) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      reject(new FetchError("Timed out fetching article"));
      return;
    }

    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value);
    };

    const transport = url.protocol === "https:" ? https : http;
    const request = transport.request(url, {
      method: "GET",
      lookup: lookupPublicAddress,
      autoSelectFamily: false,
      headers: {
        "user-agent": USER_AGENT,
        "accept": "text/html,application/xhtml+xml,text/plain;q=0.8",
        "accept-language": "en;q=0.9",
        // No decompression, so the byte cap applies to what arrives.
        "accept-encoding": "identity"
      }
    }, response => {
      const status = response.statusCode || 0;
      const location = response.headers.location;

      if (REDIRECT_CODES.has(status) && location) {
        response.destroy();
        finish(null, { redirect: location });
        return;
      }
      if (status !== 200) {
        response.destroy();
        finish(new FetchError(`Article returned HTTP ${status}`));
        return;
      }

      const contentType = String(response.headers["content-type"] || "");
      const declared = Number(response.headers["content-length"]);
      if (Number.isFinite(declared) && declared > maxBodyBytes) {
        response.destroy();
        finish(new FetchError("Article body is too large"));
        return;
      }
      if (contentType && !HTML_TYPE.test(contentType) && !/^text\/plain\b/i.test(contentType)) {
        response.destroy();
        finish(new FetchError("Article is not an HTML or text document"));
        return;
      }

      const chunks = [];
      let size = 0;
      response.on("data", chunk => {
        size += chunk.length;
        if (size > maxBodyBytes) {
          response.destroy(new FetchError("Article body is too large"));
          return;
        }
        chunks.push(chunk);
      });
      response.on("end", () => finish(null, {
        body: Buffer.concat(chunks).toString("utf8"),
        contentType
      }));
      response.on("error", () => finish(new FetchError("Article download failed")));
    });

    const timer = setTimeout(() => request.destroy(new FetchError("Timed out fetching article")), remaining);
    request.on("error", error => {
      finish(error instanceof FetchError
        ? error
        : new FetchError(`Article request failed${error.code ? ` (${error.code})` : ""}`));
    });
    request.end();
  });
}

export async function fetchPublicArticle(value, options = {}) {
  const timeoutMs = options.timeoutMs ?? FETCH_LIMITS.timeoutMs;
  const maxRedirects = options.maxRedirects ?? FETCH_LIMITS.maxRedirects;
  const maxBodyBytes = options.maxBodyBytes ?? FETCH_LIMITS.maxBodyBytes;
  const deadline = Date.now() + timeoutMs;
  let current = assertPublicUrl(value);

  for (let redirects = 0; redirects <= maxRedirects; redirects += 1) {
    const result = await requestOnce(current, { deadline, maxBodyBytes });
    if (!result.redirect) {
      return { url: current.href, body: result.body, contentType: result.contentType };
    }

    if (redirects === maxRedirects) throw new FetchError("Article redirected too many times");
    let next;
    try {
      next = assertPublicUrl(new URL(result.redirect, current).href);
    } catch (error) {
      throw error instanceof FetchError
        ? error
        : new FetchError("Article redirected to an invalid URL");
    }
    if (current.protocol === "https:" && next.protocol === "http:") {
      throw new FetchError("Refusing an HTTPS to HTTP redirect");
    }
    current = next;
  }

  throw new FetchError("Article redirected too many times");
}
