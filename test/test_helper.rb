# Load the Redmine helper
require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

#def id(sym)
#  ActiveRecord::FixtureSet.identify(sym)
#end

ActiveRecord::FixtureSet.create_fixtures(File.dirname(__FILE__) + '/fixtures/',
  [
    :issues,
    :issue_statuses,
    :users,
    :email_addresses,
    :token_votes,
    :token_payouts,
    :journals,
    :journal_details
  ])

def after_issue_status_change(issue, user, status, &block)
  with_current_user user do
    journal = issue.init_journal(user)
    issue.status = status
    issue.save!
    yield journal
    issue.clear_journal
  end
end

def TokenVote.generate!(attributes={})
  tv = TokenVote.new(attributes)
  tv.voter ||= User.first
  yield tv if block_given?
  tv.save!
  tv
end

