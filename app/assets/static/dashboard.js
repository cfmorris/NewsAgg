(function () {
  if (window.__newsaggDashboard) return;
  window.__newsaggDashboard = true;

  var appliedVersion = null;
  var pendingVersion = null;
  var focusCount = false;
  var etag;

  function versionFromDom() {
    var element = document.getElementById("archive-version");
    return element ? element.dataset.version : null;
  }

  function updateStatus() {
    var status = document.getElementById("update-status");
    if (status) status.hidden = pendingVersion === null;
  }

  function visitDashboard() {
    pendingVersion = null;
    updateStatus();
    window.Turbo.visit(window.location.href, { action: "replace" });
  }

  async function readAutoPull(options) {
    var response = await fetch("/auto-pull", { cache: "no-store", ...options });
    if (!response.ok) throw new Error("Auto-pull request failed");
    return await response.json();
  }

  function autoPullPauseText(worker) {
    var retryAt = worker.retry_at;
    var retryText = retryAt ? new Date(retryAt) : null;
    if (worker.reason === "budget") return "Paused: daily budget reached";
    if (worker.reason === "config") return "Paused: check the Neo4j configuration";
    if (worker.reason === "backoff") {
      if (!retryText || isNaN(retryText.getTime())) return "Paused: Neo4j unreachable, retrying";
      return "Paused: Neo4j unreachable, retrying " + retryText.toLocaleTimeString();
    }
    return null;
  }

  function renderAutoPull(payload) {
    var status = document.getElementById("auto-pull-status");
    if (!status || !payload) return;
    var worker = payload.worker || {};
    var failed = Boolean(worker.last_error);
    var paused = worker.running ? autoPullPauseText(worker) : null;
    var text;
    if (failed) {
      text = "Last pull failed: " + worker.last_error;
    } else if (!worker.running) {
      text = "Auto-pull needs the Rails web process running.";
    } else if (worker.in_flight) {
      text = "Pulling now…";
    } else if (paused) {
      text = paused;
    } else if (worker.last_run_at) {
      var when = new Date(worker.last_run_at);
      text = "Last pull " + (isNaN(when.getTime()) ? worker.last_run_at : when.toLocaleString());
    } else {
      text = "No pull yet";
    }
    status.textContent = text;
    status.classList.toggle("auto-pull-status-error", failed);
  }

  async function refreshAutoPull() {
    try {
      renderAutoPull(await readAutoPull());
    } catch (_) {
      // Keep the server-rendered status when the refresh fails.
    }
  }

  async function setupAutoPull() {
    var toggle = document.getElementById("auto-pull");
    var error = document.getElementById("auto-pull-error");
    if (!toggle) return;

    var enabled = toggle.checked;
    try {
      var payload = await readAutoPull();
      enabled = payload.enabled;
      toggle.checked = enabled;
      toggle.disabled = false;
      renderAutoPull(payload);
    } catch (_) {
      if (error) {
        error.textContent = "Could not load Auto-pull settings.";
        error.hidden = false;
      }
      return;
    }

    toggle.addEventListener("change", async function () {
      toggle.disabled = true;
      if (error) error.hidden = true;
      try {
        payload = await readAutoPull({
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled: toggle.checked })
        });
        enabled = payload.enabled;
        renderAutoPull(payload);
      } catch (_) {
        if (error) {
          error.textContent = "Could not update Auto-pull.";
          error.hidden = false;
        }
      } finally {
        toggle.checked = enabled;
        toggle.disabled = false;
      }
    });
  }

  var FILTERS_STATE_KEY = "newsagg.filters-panel-state";

  function filtersPanel() {
    return document.getElementById("filters-disclosure");
  }

  function storedFiltersState(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  function storeFiltersState(key, open) {
    try {
      window.localStorage.setItem(key, open ? "open" : "closed");
    } catch (_) {
      // Persistence is a convenience; the panel still works without storage.
    }
  }

  function filtersKey(panel) {
    return (panel && panel.dataset.filtersStateKey) || FILTERS_STATE_KEY;
  }

  // Re-apply the visitor's remembered open/closed choice after every render so
  // removing a filter never collapses the panel they are working in. The server
  // still renders the first-paint state; on first visit that state is recorded
  // as the visitor's starting preference.
  function applyFiltersState() {
    var panel = filtersPanel();
    if (!panel) return;
    if (window.matchMedia("(min-width: 901px)").matches) {
      panel.open = true;
      return;
    }
    var key = filtersKey(panel);
    var stored = storedFiltersState(key);
    if (stored === null) {
      storeFiltersState(key, panel.open);
      return;
    }
    panel.open = stored === "open";
  }

  function bindFiltersState() {
    var panel = filtersPanel();
    if (!panel || panel.dataset.stateBound) return;
    var summary = panel.querySelector("summary");
    if (!summary) return;
    panel.dataset.stateBound = "true";
    summary.addEventListener("click", function () {
      if (window.matchMedia("(min-width: 901px)").matches) return;
      // The default action flips `open` right after this handler runs.
      storeFiltersState(filtersKey(panel), !panel.open);
    });
  }

  function syncDisclosures() {
    applyFiltersState();
    bindFiltersState();

    document.querySelectorAll("details > summary").forEach(function (summary) {
      var details = summary.parentElement;
      function report() {
        summary.setAttribute("aria-expanded", details.open ? "true" : "false");
      }
      report();
      if (!details.dataset.expandedBound) {
        details.dataset.expandedBound = "true";
        details.addEventListener("toggle", report);
      }
    });
  }

  function submitFilters() {
    var form = document.getElementById("filter-form");
    if (form) form.requestSubmit();
  }

  function bindAutosubmit() {
    document.querySelectorAll("[data-autosubmit]").forEach(function (element) {
      if (element.dataset.autosubmitBound) return;
      element.dataset.autosubmitBound = "true";
      var eventName = element.tagName === "INPUT" && element.type === "search" ? "input" : "change";
      var timer;
      element.addEventListener(eventName, function () {
        if (element.id === "date-preset") {
          ["date-from", "date-through"].forEach(function (id) {
            var input = document.getElementById(id);
            if (input) input.value = "";
          });
        }
        if (element.id === "date-from" || element.id === "date-through") {
          var preset = document.getElementById("date-preset");
          if (preset) preset.value = "";
        }
        clearTimeout(timer);
        timer = window.setTimeout(submitFilters, eventName === "input" ? 250 : 0);
      });
    });
  }

  async function poll() {
    try {
      if (!document.hidden) {
        refreshAutoPull();
        var response = await fetch("/dashboard/stream", {
          cache: "no-store",
          headers: etag ? { "If-None-Match": etag } : {}
        });
        if (response.status !== 304 && response.ok) {
          window.Turbo.renderStreamMessage(await response.text());
          etag = response.headers.get("ETag");
          var version = versionFromDom();
          if (!version || version === appliedVersion) {
            pendingVersion = null;
            updateStatus();
          } else if (window.scrollY < 80 && document.activeElement === document.body) {
            appliedVersion = version;
            visitDashboard();
          } else {
            pendingVersion = version;
            updateStatus();
          }
        }
      }
    } catch (_) {
      // A transient failure is retried on the next poll.
    } finally {
      window.setTimeout(poll, 15_000);
    }
  }

  document.addEventListener("turbo:load", function () {
    appliedVersion = versionFromDom() || appliedVersion;
    bindAutosubmit();
    syncDisclosures();
    setupAutoPull();
    if (focusCount) {
      var count = document.getElementById("count");
      if (count) count.focus({ preventScroll: true });
      focusCount = false;
    }
  });

  // Turbo replaces the dashboard frame (and the whole page) outside of
  // turbo:load, so the remembered panel state has to be re-applied each time.
  ["turbo:frame-load", "turbo:render"].forEach(function (eventName) {
    document.addEventListener(eventName, syncDisclosures);
  });

  document.addEventListener("click", function (event) {
    if (event.target.closest("#apply-update")) {
      focusCount = true;
      appliedVersion = versionFromDom();
      visitDashboard();
    }
  });

  bindAutosubmit();
  syncDisclosures();
  appliedVersion = versionFromDom();
  window.setTimeout(poll, 15_000);
})();
/* The landing page's sign-in overlay ---------------------------------------
   The two calls to action stay ordinary links: without JavaScript they navigate
   to the Devise screens. This upgrades them. The dialog holds an iframe of the
   same Devise page with ?embedded=1, so the form keeps its CSRF token and
   renders its errors where it always does. Escape, the close control and a
   backdrop click close it, and focus goes back to the link that opened it.
   Delegated listeners keep it working after Turbo replaces the page. */
(function () {
  if (window.__newsaggAuthOverlay) return;
  window.__newsaggAuthOverlay = true;

  var lastTrigger = null;

  function overlay() {
    return document.getElementById("auth-overlay");
  }

  function frameOf(root) {
    return root ? root.querySelector(".auth-overlay-frame") : null;
  }

  function focusFrame(root) {
    var frame = frameOf(root);
    if (!root || root.hidden || !frame) return;
    try { frame.contentWindow.focus(); } catch (_) {}
  }

  // Escape pressed inside the frame never reaches the parent document, so the
  // frame's own document carries the same listener.
  function bindFrame(root) {
    var frame = frameOf(root);
    if (!frame || root.hidden) return;
    try {
      var doc = frame.contentDocument;
      if (doc && !doc.__newsaggOverlayKeys) {
        doc.__newsaggOverlayKeys = true;
        doc.addEventListener("keydown", function (event) {
          if (event.key === "Escape") close();
        });
      }
      // Land the caret on the first field so the form is usable as soon as the
      // frame paints.
      var field = doc && doc.querySelector("input[autofocus], input:not([type=hidden]), button");
      if (field) {
        field.focus();
        return;
      }
    } catch (_) {}
    focusFrame(root);
  }

  // The frame takes the embedded card's own height. A frame never shrink-wraps
  // its document, and it used to carry a fixed 520px that fitted no form: the
  // card scrolled inside it and both ends were cut off. Measuring with the
  // document's own scrollbar hidden keeps the width the card will really have -
  // a scrollbar would narrow it and inflate the height we read.
  function fitFrame(root) {
    var frame = frameOf(root);
    if (!root || root.hidden || !frame) return;

    var doc, card;
    try {
      doc = frame.contentDocument;
      card = doc && doc.querySelector(".auth-card");
    } catch (_) {
      return;
    }
    if (!card) return;

    var html = doc.documentElement;
    html.style.overflowY = "hidden";
    var height = Math.ceil(card.getBoundingClientRect().height + card.offsetTop);
    html.style.overflowY = "";

    // The stylesheet caps the frame at the viewport; past that the card scrolls
    // inside the frame and the close control stays where it is.
    if (height > 0) frame.style.height = height + "px";
  }

  function open(link) {
    var root = overlay();
    var frame = frameOf(root);
    var title = document.getElementById("auth-overlay-title");
    var source = link.getAttribute("data-auth-overlay-src") || link.getAttribute("href");
    if (!root || !frame || !source) return;

    lastTrigger = link;
    var label = link.getAttribute("data-auth-overlay") === "sign-up" ? "Create account" : "Sign in";
    if (title) title.textContent = label;
    frame.title = label + " to NewsAgg";
    frame.onload = function () { fitFrame(root); bindFrame(root); };
    frame.src = source;

    root.hidden = false;
    document.body.classList.add("auth-overlay-open");
    var closeButton = root.querySelector("[data-auth-overlay-close]");
    if (closeButton) closeButton.focus();
    else focusFrame(root);
  }

  function close() {
    var root = overlay();
    if (!root || root.hidden) return;
    root.hidden = true;
    document.body.classList.remove("auth-overlay-open");
    var frame = frameOf(root);
    if (frame) {
      frame.onload = null;
      frame.src = "about:blank";
    }
    if (lastTrigger && lastTrigger.isConnected) lastTrigger.focus();
    lastTrigger = null;
  }

  // A deep link to sign-in lands on /?auth=sign-in, and the landing page names
  // the card to open. Open it through the same [data-auth-overlay] link a click
  // would use, so the frame source, the title and the focus all behave alike.
  function autoload() {
    var main = document.querySelector("[data-auth-autoload]");
    var name = main && main.getAttribute("data-auth-autoload");
    var root = overlay();
    if (!name || !root || !root.hidden) return;

    var links = document.querySelectorAll("[data-auth-overlay]");
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute("data-auth-overlay") === name) {
        open(links[i]);
        return;
      }
    }
  }

  document.addEventListener("turbo:load", autoload);
  // The script is deferred, so the document is already parsed here; the
  // readyState branch covers the same script served without defer.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", autoload);
  } else {
    autoload();
  }

  document.addEventListener("click", function (event) {
    if (!event.target || !event.target.closest) return;

    var link = event.target.closest("[data-auth-overlay]");
    if (link) {
      // Modified clicks and the href fallback keep their native behaviour.
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      open(link);
      return;
    }

    var root = overlay();
    if (!root || root.hidden) return;
    // The close control, or the backdrop around the dialog.
    if (event.target.closest("[data-auth-overlay-close]") || event.target === root) {
      event.preventDefault();
      close();
    }
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") close();
  });
})();
