class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false, default: ""
      t.string :encrypted_password, null: false, default: ""

      # recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at

      # rememberable
      t.datetime :remember_created_at

      # trackable
      t.integer :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip

      # lockable
      t.integer :failed_attempts, null: false, default: 0
      t.string :unlock_token
      t.datetime :locked_at

      # devise-two-factor; the secret is stored encrypted by the model
      t.string :otp_secret
      t.integer :consumed_timestep
      t.boolean :otp_required_for_login, null: false, default: false

      # OAuth-ready from day one; no strategy is configured yet
      t.string :provider
      t.string :uid

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :reset_password_token, unique: true
    add_index :users, :unlock_token, unique: true
    # SQLite, like Postgres, treats NULLs as distinct, so password-only accounts
    # (provider and uid both NULL) never collide with each other.
    add_index :users, [:provider, :uid], unique: true
  end
end
