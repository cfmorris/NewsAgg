# Per-account dismissals. This is reader state, not archive state, so it lives
# in SQLite next to users rather than as a Neo4j property: two readers share one
# article node but not one hidden flag.
class CreateHiddenArticles < ActiveRecord::Migration[8.1]
  def change
    create_table :hidden_articles do |t|
      t.references :user, null: false, foreign_key: true, index: false
      # The archive has no id column; url is the stable identity it orders by.
      t.string :article_url, null: false
      t.datetime :hidden_at, null: false
      t.timestamps
    end

    add_index :hidden_articles, [:user_id, :article_url], unique: true
    add_index :hidden_articles, :user_id
  end
end
