class Pullermann

  attr_accessor :username,
                :password,
                :username_fail,
                :password_fail,
                :rerun_on_source_change,
                :rerun_on_target_change,
                :prepare_block,
                :test_block,
                :log_level

  # Allow configuration blocks being passed to Pullermann.
  def self.setup
    yield main_instance
  end

  def test_preparation(&block)
    self.prepare_block = block
  end

  def test_execution(&block)
    self.test_block = block
  end

  # The main Pullermann task. Call this to start testing.
  def self.run
    main_instance.run
  end

  def run
    # Populate variables and setup environment.
    configure
    # Loop through all 'open' pull requests.
    pull_requests.each do |request|
      @request_id = request['number']
      # Jump to next iteration if source and/or target haven't change since last run.
      next unless test_run_necessary?
      # GitHub always creates a merge commit for its 'Merge Button'.
      switch_branch_to_merged_state
      # Prepare project and CI (e.g. Jenkins) for the test run.
      self.prepare_block.call
      # Run specified tests for the project.
      # NOTE: Either ensure the last call in that block runs your tests
      # or manually set @result to a boolean inside this block.
      self.test_block.call
      # Unless already set, the success/failure is determined by the last
      # command's return code.
      @test_success ||= $? == 0
      # We need to switch back to the original branch in case we need to test
      # more pull requests.
      switch_branch_back
      comment_on_github
    end
  end


  private

  # Remember the one instance we setup in our application and want to run.
  def self.main_instance
    @main_instance ||= Pullermann.new
  end

  def configure
    @log = Logger.new(STDOUT)
    @log.level = self.log_level || Logger::INFO
    # Set default fall back values for options that aren't set.
    self.username ||= git_config['github.login']
    self.password ||= git_config['github.password']
    self.username_fail ||= self.username
    self.password_fail ||= self.password
    self.rerun_on_source_change = true unless self.rerun_on_source_change == false
    self.rerun_on_target_change = true unless self.rerun_on_target_change == false
    # Find environment (tasks, project, ...).
    @prepare_block ||= lambda {}
    @test_block ||= lambda { `rake test` }
    @github = connect_to_github
    @github_fail = if self.username == self.username_fail
      @github
    else
      connect_to_github self.username_fail, self.password_fail
    end
  end

  def connect_to_github(user = self.username, pass = self.password)
    github = Octokit::Client.new(
      :login => user,
      :password => pass
    )
    # Check user login to GitHub.
    github.login
    @log.info "Successfully logged into GitHub (API v#{github.api_version}) with user '#{user}'."
    # Ensure the user has access to desired project.
    @project ||= /:(.*)\.git/.match(git_config['remote.origin.url'])[1]
    begin
      github.repo @project
      @log.info "Successfully accessed GitHub project '#{@project}'"
      github
    rescue Octokit::Unauthorized => e
      @log.error "Unable to access GitHub project with user '#{user}':\n#{e.message}"
      abort
    end
  end

  def pull_requests
    pulls = @github.pulls @project, 'open'
    @log.info "Found #{pulls.size > 0 ? pulls.size : 'no'} open pull requests in '#{@project}'."
    pulls
  end

  # Test runs are necessary if:
  # - the pull request hasn't been tested before.
  # - the pull request has been updated since the last run.
  # - the target (i.e. master) has been updated since the last run.
  def test_run_necessary?
    pull_request = @github.pull_request @project, @request_id
    @log.info "Checking pull request ##{@request_id}: #{pull_request.title}"
    # Compare current sha ids of target and source branch with those from the last test run.
    @target_head_sha = @github.commits(@project).first.sha
    @pull_head_sha = pull_request.head.sha
    comments = @github.issue_comments(@project, @request_id)
    comments = comments.select{ |c| [username, username_fail].include?(c.user.login) }.reverse
    # Initialize shas to ensure it will live on after the 'each' block.
    shas = nil
    comments.each do |comment|
      shas = /master sha# ([\w]+) ; pull sha# ([\w]+)/.match(comment.body)
      if shas && shas[1] && shas[2]
        # Remember @comment to be able to update or delete it later.
        @comment = comment
        break
      end
    end
    # If it's not mergeable, we need to delete all comments of former test runs.
    unless pull_request.mergeable
      @log.info 'Pull request not auto-mergeable. Not running tests.'
      if @comment
        @log.info 'Deleting existing comment.'
        call_github(old_comment_success?).delete_comment(@project, @comment.id)
      end
      return false
    end
    if @comment
      @log.info "Current target sha: '#{@target_head_sha}', pull sha: '#{@pull_head_sha}'."
      @log.info "Last test run target sha: '#{shas[1]}', pull sha: '#{shas[2]}'."
      if self.rerun_on_source_change && (shas[2] != @pull_head_sha)
        @log.info 'Re-running test due to new commit in pull request.'
        return true
      elsif self.rerun_on_target_change && (shas[1] != @target_head_sha)
        @log.info 'Re-running test due to new commit in target branch.'
        return true
      end
    else
      # If there are no comments yet, it has to be a new request.
      @log.info 'New pull request detected, test run needed.'
      return true
    end
    @log.info "Not running tests for request ##{@request_id}."
    false
  end

  def switch_branch_to_merged_state
    # Fetch the merge-commit for the pull request.
    # NOTE: This commit is automatically created by 'GitHub Merge Button'.
    # FIXME: Use cheetah to pipe to @log.debug instead of that /dev/null hack.
    `git fetch origin refs/pull/#{@request_id}/merge: &> /dev/null`
    `git checkout FETCH_HEAD &> /dev/null`
    unless $? == 0
      @log.error 'Unable to switch to merge branch.'
      abort
    end

  end

  def switch_branch_back
    # FIXME: Use cheetah to pipe to @log.debug instead of that /dev/null hack.
    @log.info 'Switching back to original branch.'
    # FIXME: For branches other than master, remember the original branch.
    `git co master &> /dev/null`
  end

  # Analyze old comment to see whether it was a successful or a failing one.
  def old_comment_success?
    return unless @comment
    # Determine boolean value.
    @comment.body.include? 'Well done!'
  end

  # Output the result to a comment on the pull request on GitHub.
  def comment_on_github
    # Determine comment message.
    message = if @test_success
      @log.info 'Tests are passing.'
      'Well done! All tests are still passing after merging this pull request.'
    else
      @log.info 'Tests are failing.'
      'Unfortunately your tests are failing after merging this pull request.'
    end
    message += "\n( master sha# #{@target_head_sha} ; pull sha# #{@pull_head_sha} )"
    if old_comment_success? == @test_success
      # Replace existing @comment's body with the correct connection.
      @log.info "Updating existing #{notion(@test_success)} comment."
      call_github(@test_success).update_comment(@project, @comment['id'], message)
    else
      @log.info "Deleting existing #{notion(!@test_success)} comment."
      # Delete old @comment with correct connection (if @comment exists).
      call_github(!@test_success).delete_comment(@project, @comment['id']) if @comment
      # Create new comment with correct connection.
      @log.info "Adding new #{notion(@test_success)} comment."
      call_github(@test_success).add_comment(@project, @request_id, message)
    end
  end

  def notion(success)
    success ? 'positive' : 'negative'
  end

  # Determine which connection to GitHub should be used for the call.
  def call_github(use_default_user = true)
    use_default_user ? @github : @github_fail
  end

  # Collect git config information in a Hash for easy access.
  # Checks '~/.gitconfig' for credentials.
  def git_config
    unless @git_config
      # Read @git_config from local git config.
      @git_config = {}
      `git config --list`.split("\n").each do |line|
        key, value = line.split('=')
        @git_config[key] = value
      end
    end
    @git_config
  end

end
