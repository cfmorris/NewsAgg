# Establishes the application's migration baseline. Domain tables (users and
# sessions) arrive with the accounts card; this migration only proves the
# database can be prepared and migrated.
class CreateNewsArchiveSchema < ActiveRecord::Migration[8.1]
  def change
  end
end
