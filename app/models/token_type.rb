class TokenType < ActiveRecord::Base
  validates :name, :rpc_uri, presence: true
  validates :min_conf, numericality: { greater_than_or_equal_to: 0 }
  validates :last_synced_block, numericality: { greater_than_or_equal_to: -1 }
  validates :default, inclusion: [true, false]
end

