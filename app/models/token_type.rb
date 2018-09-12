class TokenType < ActiveRecord::Base
  validates :name, presence: true, uniqueness: true
  validates :rpc_uri, presence: true
  validates_each :rpc_uri do |record, attr, value|
    begin
      rpc = RPC::get_rpc(record.name, value)
      uri = rpc.uri.to_s
      rpc.uptime
    rescue RPC::ClassMissing => e
      record.errors.add(attr, e.message)
    rescue RPC::Error, URI::Error => e
      record.errors.add(attr, "Cannot connect to #{record.name} RPC #{uri}: #{e.message}")
    end
  end
  validates :min_conf, numericality: { greater_than: 0 }
  validates :precision, numericality: { greater_than_or_equal_to: 0 }
  validates :is_default, inclusion: [true, false]
  validates :prev_sync_height, numericality: { greater_than_or_equal_to: 0 }


  after_initialize :set_defaults

  protected

  def set_defaults
    if new_record?
      self.rpc_uri ||= 'http://rpcuser:rpcpassword@hostname:8332'
      self.min_conf ||= 6
      self.precision ||= 8
      self.is_default ||= false
      self.prev_sync_height ||= 0
    end
  end
end

