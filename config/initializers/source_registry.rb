# Loads the explicit source allowlist (config/sources.yml) at boot and exposes
# it to the application as SourceRegistry.current and
# Rails.application.config.x.source_registry.
#
# A missing, unreadable, or malformed allowlist raises
# SourceRegistry::ConfigError here, so boot fails with the file path, the entry
# index, and the reason instead of falling back to any built-in feed. Set
# NEWSAGG_SOURCES_PATH to point at another file.
require Rails.root.join("app", "services", "source_registry")

Rails.application.config.x.source_registry = SourceRegistry.load!
