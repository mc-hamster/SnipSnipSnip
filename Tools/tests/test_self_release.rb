require "minitest/autorun"
require "shellwords"
require "tempfile"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require "json"
require_relative "../../fastlane/self_release_support"

# Exercise the real publishing lane with command spies: no network, credentials,
# archive, keychain, notarization, or GitHub mutation is performed by these tests.
module Actions
  class << self
    attr_accessor :commands, :fail_reservation, :notes
    def sh(command, **_options)
      arguments = Shellwords.split(command)
      self.commands << arguments
      if arguments.include?("POST") && fail_reservation
        raise "Reference already exists"
      end
      if arguments[0, 3] == ["gh", "release", "create"]
        self.notes = File.read(arguments[arguments.index("--notes-file") + 1])
      end
      ""
    end
  end
end

module UI
  def self.user_error!(message)
    raise message
  end
  def self.message(_message); end
  def self.success(_message); end
end

class SelfReleasePolicyTests < Minitest::Test
  def test_build_allocation_includes_published_beta_and_reserved_tags
    tags = ["v1.2.0-self.191", "v1.2.0-beta.197", "v1.1.9-self.195", "unrelated-9000"]
    assert_equal 198, SelfReleaseSupport.next_build_number(192, tags)
    assert_equal 201, SelfReleaseSupport.next_build_number(200, tags)
    assert_equal 193, SelfReleaseSupport.next_build_number(192, [])
  end

  def test_workflow_preserves_changelog_as_one_literal_argument
    workflow = YAML.load_file(File.expand_path("../../.github/workflows/release-self-release.yml", __dir__))
    script = workflow.fetch("jobs").fetch("release").fetch("steps")
                     .find { |step| step["name"] == "Fastlane self release publish" }.fetch("run")
    Dir.mktmpdir("self-release-arguments") do |directory|
      FileUtils.mkdir_p(File.join(directory, "bin"))
      launcher = File.join(directory, "bin", "fastlane")
      File.write(launcher, "#!/usr/bin/env ruby\nrequire 'json'\nFile.write(ENV.fetch('ARGUMENTS_PATH'), ARGV.to_json)\n")
      File.chmod(0755, launcher)
      changelog = "Fix \"quotes\" and spaces; $(touch injected) `touch injected`\nSecond line"
      arguments_path = File.join(directory, "arguments.json")
      _output, errors, status = Open3.capture3(
        { "RELEASE_PRERELEASE" => "false", "RELEASE_DRAFT" => "true",
          "RELEASE_CHANGELOG" => changelog, "ARGUMENTS_PATH" => arguments_path },
        "bash", "-c", script, chdir: directory
      )
      assert status.success?, errors
      assert_equal ["mac", "self_release_publish", "prerelease:false", "draft:true", "changelog:#{changelog}"],
                   JSON.parse(File.read(arguments_path))
      refute File.exist?(File.join(directory, "injected"))
    end
  end

  def setup
    Actions.commands = []
    Actions.fail_reservation = false
    Actions.notes = nil
    @package = Tempfile.new(["self-release-fixture", ".pkg"])
    @lane = Object.new
    package_path = @package.path
    @lane.define_singleton_method(:self_release_pkg_path) { package_path }
    @lane.define_singleton_method(:private_lane) do |name, &body|
      define_singleton_method(name, &body)
    end
    @lane.define_singleton_method(:required_env!) { |_name| "fixture-only" }
    @lane.define_singleton_method(:current_git_commit) { "abc123-built-commit" }
    @lane.define_singleton_method(:self_release_repository) { |_options| "owner/repo" }
    @lane.define_singleton_method(:tracked_changelog_details) do |**_options|
      { text: "Fix spaces, 'quotes', \"double quotes\", $HOME and `commands`\nSecond line", source: "manual" }
    end
    @lane.define_singleton_method(:boolean_option) do |value, default_value: false|
      value.nil? ? default_value : value.to_s == "true"
    end
    @lane.define_singleton_method(:persist_upload_record) { |**_options| }
    @lane.define_singleton_method(:record_fastlane_run_metadata) { |**_options| }
    source = File.read(File.expand_path("../../fastlane/Fastfile", __dir__))
    publishing_lane = source.split("private_lane :publish_self_release_package", 2).last
                            .split("private_lane :build_release_pkg", 2).first
    @lane.instance_eval("private_lane :publish_self_release_package" + publishing_lane)
  end

  def teardown
    @package.close!
  end

  def publish(**options)
    guard = Object.new
    guard.define_singleton_method(:verify!) { |**_| true }
    @lane.publish_self_release_package({ prepared: { version: "1.2.0", build_number: 198, source_commit: "abc123-built-commit", source_guard: guard } }.merge(options))
  end

  def test_source_changes_stop_publication_before_tag_reservation
    guard = Object.new
    guard.define_singleton_method(:verify!) { |**_| raise "Source changed" }
    assert_raises(RuntimeError) do
      publish(prepared: { version: "1.2.0", build_number: 198, source_commit: "abc123-built-commit", source_guard: guard })
    end
    refute Actions.commands.any? { |args| args.include?("POST") || args[0, 2] == ["gh", "release"] }
  end

  def test_reserves_tag_at_built_commit_before_creating_draft
    publish(draft: true)
    reservation = Actions.commands.find { |args| args.include?("POST") }
    assert_includes reservation, "sha=abc123-built-commit"
    assert_includes reservation, "ref=refs/tags/v1.2.0-self.198"
    creation = Actions.commands.find { |args| args[0, 3] == ["gh", "release", "create"] }
    assert_includes creation, "--verify-tag"
    assert_includes creation, "--draft"
    assert_includes creation, @package.path
    assert_operator Actions.commands.index(reservation), :<, Actions.commands.index(creation)
    refute Actions.commands.flatten.include?("--clobber")
    assert_includes Actions.notes, "$HOME and `commands`\nSecond line"
  end

  def test_mismatched_tag_is_rejected_before_reserving_or_uploading
    assert_raises(RuntimeError) { publish(tag: "v1.1.0-self.123") }
    refute Actions.commands.any? { |args| args.include?("POST") || args[0, 2] == ["gh", "release"] }
  end

  def test_existing_tag_fails_without_uploading_or_changing_release
    Actions.fail_reservation = true
    assert_raises(RuntimeError) { publish(draft: true) }
    refute Actions.commands.any? { |args| args[0, 2] == ["gh", "release"] }
  end

  def test_prerelease_is_never_latest_and_stable_is_explicit
    publish
    creation = Actions.commands.last
    assert_includes creation, "--prerelease"
    assert_includes creation, "--latest=false"
    Actions.commands = []
    publish(prerelease: false)
    refute_includes Actions.commands.last, "--prerelease"
    refute_includes Actions.commands.last, "--latest=false"
  end
end

class SelfReleaseSourceTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir("self-release-source")
    @project = File.join(@root, "Example.xcodeproj")
    FileUtils.mkdir_p(@project)
    @project_file = File.join(@project, "project.pbxproj")
    @project_contents = "// 日本語 project fixture\n\tCURRENT_PROJECT_VERSION = 192;\n\tMARKETING_VERSION = 1.2.0;\n"
    File.write(@project_file, @project_contents)
    File.write(File.join(@root, "Source.swift"), "// Committed source\n")
    git("init", "--quiet")
    git("add", ".")
    git("-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "--quiet", "-m", "Fixture")
    @commit = git("rev-parse", "HEAD").strip
    @source = SelfReleaseSupport::PublishSource.new(repository_root: @root, project_path: @project, commit: @commit)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_committed_source_and_exact_build_bump_are_allowed
    assert @source.verify!
    bump_build
    assert @source.verify!(build_number: 198)
  end

  def test_uncommitted_source_edit_with_unchanged_head_is_rejected
    bump_build
    File.write(File.join(@root, "Source.swift"), "// Editor saved during archive\n")
    assert_equal @commit, git("rev-parse", "HEAD").strip
    assert_raises(RuntimeError) { @source.verify!(build_number: 198) }
  end

  def test_build_bump_does_not_allow_other_project_changes
    bump_build
    File.open(@project_file, "a") { |file| file.puts "\tOTHER_SWIFT_FLAGS = -DCHANGED;" }
    assert_raises(RuntimeError) { @source.verify!(build_number: 198) }
  end

  def test_untracked_source_and_deleted_source_are_rejected
    extra = File.join(@root, "Added.swift")
    File.write(extra, "// New input\n")
    assert_raises(RuntimeError) { @source.verify! }
    File.delete(extra)
    File.delete(File.join(@root, "Source.swift"))
    assert_raises(RuntimeError) { @source.verify! }
  end

  def test_commit_change_is_rejected_even_when_file_contents_are_identical
    git("-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "Moved HEAD")
    assert_raises(RuntimeError) { @source.verify! }
  end

  def test_initial_source_must_match_the_commit
    File.write(File.join(@root, "Source.swift"), "// Changed before verification\n")
    assert_raises(RuntimeError) do
      SelfReleaseSupport::PublishSource.new(repository_root: @root, project_path: @project, commit: @commit)
    end
  end

  def test_snapshot_uses_only_the_commit_and_keeps_build_edits_isolated
    snapshot_path = nil
    result = SelfReleaseSupport.with_source_snapshot(repository_root: @root, commit: @commit) do |snapshot|
      snapshot_path = snapshot
      snapshot_project = File.join(snapshot, "Example.xcodeproj")
      snapshot_source = SelfReleaseSupport::PublishSource.new(repository_root: snapshot, project_path: snapshot_project, commit: @commit)
      File.write(File.join(@root, "Source.swift"), "// Edited during archive\n")
      assert_equal "// Committed source\n", File.read(File.join(snapshot, "Source.swift"))
      snapshot_source.apply_build_number!(198)
      assert snapshot_source.verify!(build_number: 198)
      assert_equal @project_contents, File.read(@project_file)
      assert_equal @project_contents.sub("192", "198"), File.read(File.join(snapshot_project, "project.pbxproj"))
      :built
    end
    assert_equal :built, result
    refute File.exist?(snapshot_path)
  end

  def test_snapshot_is_removed_after_a_failed_build
    snapshot_path = nil
    assert_raises(RuntimeError) do
      SelfReleaseSupport.with_source_snapshot(repository_root: @root, commit: @commit) do |snapshot|
        snapshot_path = snapshot
        raise "Build failed"
      end
    end
    refute File.exist?(snapshot_path)
  end

  def test_publishing_lane_tests_and_archives_the_same_snapshot
    events = []
    prepared = run_release_lane(events: events)
    assert_equal @commit, prepared[:source_commit]
    tests = events.find { |event| event.first == :tests }
    archive = events.find { |event| event.first == :archive }
    assert_equal tests[1], archive[1]
    refute_equal @project, archive[1]
    assert_equal "// Committed source\n", archive[2]
    assert_equal @project_contents.sub("192", "198"), archive[3]
    assert events.any? { |event| event.first == :publish }
    refute File.exist?(archive[1])
  end

  def test_publishing_lane_rejects_edits_during_tests
    assert_lane_rejects_edit_at(:tests)
  end

  def test_publishing_lane_rejects_edits_during_archive
    assert_lane_rejects_edit_at(:archive)
  end

  def test_publishing_lane_rejects_edits_during_notarization
    assert_lane_rejects_edit_at(:notarization)
  end

  def test_build_only_lane_keeps_using_the_requested_checkout
    events = []
    run_release_lane(events: events, publish: false)
    assert_equal @project, events.find { |event| event.first == :archive }[1]
    refute events.any? { |event| event.first == :publish }
  end

  private

  def assert_lane_rejects_edit_at(stage)
    events = []
    error = assert_raises(RuntimeError) do
      run_release_lane(events: events, edit_at: stage)
    end
    assert_match(/Source changed during release preparation/, error.message)
    refute events.any? { |event| event.first == :publish }
  end

  # Execute the actual public lane with local Git fixtures and spies for the
  # expensive/external steps. Verify the snapshot routing as well as the guard.
  def run_release_lane(events:, edit_at: nil, publish: true)
    Actions.commands = []
    lane = Module.new
    lane.const_set(:REPOSITORY_ROOT, @root)
    lane.const_set(:PROJECT_PATH, @project)
    lane.define_singleton_method(:lane) { |name, &body| define_singleton_method(name, &body) }
    lane.define_singleton_method(:boolean_option) { |value, default_value: false| value.nil? ? default_value : value.to_s == "true" }
    head = @commit
    lane.define_singleton_method(:current_git_commit) { head }
    source_file = File.join(@root, "Source.swift")
    project_file = @project_file
    mutate = ->(stage) { File.write(source_file, "// Saved during #{stage}\n") if edit_at == stage }
    lane.define_singleton_method(:run_release_test_gate) do |options|
      events << [:tests, options.fetch(:project_path)]
      mutate.call(:tests)
    end
    lane.define_singleton_method(:ensure_self_release_signing_ready) {}
    lane.define_singleton_method(:prepare_local_version_and_build_number) do |*_options|
      File.write(project_file, File.read(project_file).sub("192", "198"))
      { version: "1.2.0", build_number: 198 }
    end
    lane.define_singleton_method(:build_release_pkg) do |options|
      project = options.fetch(:project_path)
      events << [:archive, project, File.read(File.join(File.dirname(project), "Source.swift")),
                 File.read(File.join(project, "project.pbxproj"))]
      mutate.call(:archive)
    end
    lane.define_singleton_method(:notarize_self_release_package) do
      events << [:notarization]
      mutate.call(:notarization)
    end
    lane.define_singleton_method(:publish_self_release_package) do |options|
      options.fetch(:prepared).fetch(:source_guard).verify!(build_number: 198)
      events << [:publish]
    end
    lane.define_singleton_method(:record_fastlane_run_metadata) { |**_| }
    source = File.read(File.expand_path("../../fastlane/Fastfile", __dir__))
    body = source.split("  lane :self_release do |options|", 2).last
                 .split('  desc "Build and publish the Self Release package', 2).first
    lane.module_eval("self.lane(:self_release) do |options|" + body)
    lane.self_release(publish: publish)
  end

  def bump_build
    File.write(@project_file, @project_contents.sub("192", "198"))
  end

  def git(*arguments)
    output, errors, status = Open3.capture3("git", "-C", @root, *arguments)
    raise errors unless status.success?
    output
  end
end
