# Roles and the disabled flag that makes Devise refuse a disabled account.
class AddRoleAndDisabledAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :integer, null: false, default: 0
    add_index :users, :role
    add_column :users, :disabled_at, :datetime, null: true
  end
end
