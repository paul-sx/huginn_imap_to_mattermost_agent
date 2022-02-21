require 'rails_helper'
require 'huginn_agent/spec_helper'

describe Agents::ImapToMattermostAgent do
  before(:each) do
    @valid_options = Agents::ImapToMattermostAgent.new.default_options
    @checker = Agents::ImapToMattermostAgent.new(:name => "ImapToMattermostAgent", :options => @valid_options)
    @checker.user = users(:bob)
    @checker.save!
  end

  pending "add specs here"
end
