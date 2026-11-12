require "pathname"

require_relative "../../config/environment"
require_relative "../support/assertions"

# Verifies the relational store the accounts work will build on: the app boots
# with ActiveRecord against SQLite, the test database is its own file, and the
# migration bookkeeping table exists (proving db:migrate ran).
include TestReport

# database.yml paths are relative to the application root; expand them so the
# comparison is about the file each environment actually opens.
def database_path(env_name)
  config = ActiveRecord::Base.configurations.configs_for(env_name: env_name, name: "primary")
  raise "no primary database configured for #{env_name}" unless config

  path = Pathname.new(config.database.to_s)
  path.absolute? ? path.cleanpath : Rails.root.join(path).cleanpath
end

TestReport.run do
  check "ActiveRecord::Base.connection opens the sqlite3 adapter" do
    connection = ActiveRecord::Base.connection
    assert connection, "ActiveRecord::Base.connection returned nil"
    assert connection.adapter_name.to_s.downcase.include?("sqlite"),
           "expected the sqlite3 adapter, got #{connection.adapter_name.inspect}"
  end

  check "the test database is a separate file from the development database" do
    development = database_path("development")
    test = database_path("test")
    assert development.to_s.end_with?(".sqlite3"), "development database is not a sqlite3 file: #{development}"
    assert test.to_s.end_with?(".sqlite3"), "test database is not a sqlite3 file: #{test}"
    assert development != test, "test and development share the same database file: #{test}"
  end

  check "a migration has run (schema_migrations exists)" do
    assert ActiveRecord::Base.connection.table_exists?("schema_migrations"),
           "schema_migrations table is missing; db:migrate/db:prepare has not run"
  end
end
