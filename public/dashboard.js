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

  function renderAutoPull(payload) {
    var status = document.getElementById("auto-pull-status");
    if (!status || !payload) return;
    var worker = payload.worker || {};
    var failed = Boolean(worker.last_error);
    var text;
    if (failed) {
      text = "Last pull failed: " + worker.last_error;
    } else if (!worker.running) {
      text = "Auto-pull needs the Rails web process running.";
    } else if (worker.in_flight) {
      text = "Pulling now…";
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
          ["date-from", "date-through", "published-from", "published-through"].forEach(function (id) {
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
    setupAutoPull();
    if (focusCount) {
      var count = document.getElementById("count");
      if (count) count.focus({ preventScroll: true });
      focusCount = false;
    }
  });

  document.addEventListener("click", function (event) {
    if (event.target.closest("#apply-update")) {
      focusCount = true;
      appliedVersion = versionFromDom();
      visitDashboard();
    }
  });

  bindAutosubmit();
  appliedVersion = versionFromDom();
  window.setTimeout(poll, 15_000);
})();