# Load the Redmine helper
require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')
require 'webrick'

ActiveRecord::FixtureSet.create_fixtures(File.dirname(__FILE__) + '/fixtures/',
  [
    :issues,
    :issue_statuses,
    :users,
    :email_addresses,
    :token_votes,
    :token_payouts,
    :token_types,
    :journals,
    :journal_details,
    :projects,
    :roles,
    :members,
    :member_roles,
    :enabled_modules,
    :workflow_transitions,
    :trackers
  ])

def setup_plugin
  Setting.plugin_token_voting = {
    'checkpoints' => {
      'statuses' => [[issue_statuses(:resolved).id.to_s],
                     [issue_statuses(:pulled).id.to_s],
                     [issue_statuses(:closed).id.to_s]],
    'shares' => ['0.7', '0.2', '0.1']
    }
  }
end

def Issue.update_status!(issue, user, status, &block)
  saved_user = User.current
  User.current = user

  journal = issue.init_journal(user)
  issue.status = status
  issue.save!
  TokenVote.issue_edit_hook(issue, journal)
  issue.clear_journal
ensure
  User.current = saved_user
end

def TokenVote.generate!(attributes={})
  tv = TokenVote.new(attributes)
  tv.voter ||= User.take
  tv.issue ||= Issue.take
  tv.duration ||= 1.month
  tv.token_type ||= token_types(:BTCREG)
  yield tv if block_given?
  tv.generate_address
  tv.save!
  tv
end

def logout_user
  post signout_path
end

def create_token_vote(issue=issues(:issue_01), attributes={})
  attributes[:token_type_id] ||= token_types(:BTCREG).id
  attributes[:duration] ||= 1.day

  assert_difference 'TokenVote.count', 1 do
    post "#{issue_token_votes_path(issue)}.js", params: {token_vote: attributes}
    assert_nil flash[:error]
  end
  assert_response :ok

  TokenVote.last
end

def destroy_token_vote(vote)
  assert_difference 'TokenVote.count', -1 do
    delete "#{token_vote_path(vote)}.js"
    assert_nil flash[:error]
  end
  assert_response :ok
end

def fund_token_vote(vote, amount)
  assert_notifications 'walletnotify' => 1, 'blocknotify' => 0 do
    @network.send_to_address(vote.address, amount)
  end
  vote.reload
end

def generate_blocks(count)
  assert_notifications 'blocknotify' => count do
    @network.generate(count)
  end
  TokenVote.all.reload
end

def update_issue_status(issue, status)
  put "/issues/#{issue.id}", params: {issue: {status_id: status.id}}
  issue.reload
  assert_equal issue.status_id, status.id
end

module TokenVoting
  class NotificationIntegrationTest < Redmine::IntegrationTest
    # Forces all threads to share the same connection. Necessary for
    # running notifications through webrick, because it starts separate thread.
    # source: https://gist.github.com/josevalim/470808
    class ActiveRecord::Base
      mattr_accessor :shared_connection
      @@shared_connection = nil
      def self.connection
        @@shared_connection || retrieve_connection
      end
    end
    ActiveRecord::Base.shared_connection = ActiveRecord::Base.connection

    # Forces exclusive access to same connection - race conditions happen
    # when multiple threads use same connection simultaneously.
    raise "adapter was expected to be mysql2" unless
      ActiveRecord::Base.connection.adapter_name.downcase == "mysql2"

    module MutexLockedQuerying
      @@semaphore = Mutex.new
      def query(*)
        @@semaphore.synchronize { super }
      end
    end
    Mysql2::Client.prepend(MutexLockedQuerying)
    
    @@webrick = nil
    def setup
      super
      setup_plugin

      # Expecting to work with at least 2 nodes: one working as wallet and the
      # other as rest of network (from where payments are incoming).
      # Configurations for bitcoind are in test/configs/bitcoind-regtest-* dirs.
      @network = RPC.get_rpc(token_types(:BTCREGNetwork))
      if @network.get_wallet_info['balance'] < 100.0
        @network.generate(110)
      end
      btcreg = token_types(:BTCREG)
      @wallet = RPC.get_rpc(btcreg)
      btcreg.prev_sync_height = @wallet.get_block_count
      btcreg.save!

      @notifications = Hash.new(0)
      ActiveSupport::Notifications.subscribe 'process_action.action_controller' do |*args|
        data = args.extract_options!
        @notifications[data[:action]] += 1 if data[:controller] == 'TokenVotesController'
      end

      return if @@webrick
      # Setup server for receiving notifications (application server is not running
      # during tests).
      server = WEBrick::HTTPServer.new(
        Port: 3000,
        Logger: WEBrick::Log.new("/dev/null"),
        AccessLog: []
      )
      server.mount_proc '/' do |req, resp|
        headers = {}
        req.header.each { |k,v| v.each { |a| headers[k] = a } }
        resp = self.get req.path, {}, headers
      end
      @@webrick = Thread.new {
        server.start
      }
      Minitest.after_run do
        @@webrick.kill
        @@webrick.join
      end
      Timeout.timeout(5) do
        sleep 0.1 until server.status == :Running
      end
    end

    def teardown
      super
      ActiveSupport::Notifications.unsubscribe 'process_action.action_controller'
    end

    # Waits for expected number of notifications to occur before timeout.
    # Also checks if there were no superfluous notifications after completion.
    def assert_notifications(expected={})
      @notifications.clear
      expected.each { |k,v| @notifications[k] = 0 }
      yield

      begin
        Timeout.timeout(3) do
          sleep 0.1 until expected <= @notifications
        end
      rescue Timeout::Error
        # do nothing, final assert checks validity of result
      ensure
        # catch superfluous notifications if any
        sleep 0.5
        assert_operator expected, :<=, @notifications
      end
    end

    # Waits for tx to arrive into node's mempool before timeout.
    def assert_in_mempool(node, txid)
      #byebug
      Timeout.timeout(10) do
        sleep 0.1 while node.get_mempool_entry(txid).empty?
      end
    rescue Timeout::Error
      raise Timeout::Error, "Timeout while waiting on #{node} for txid #{txid}."
    end
  end
end

