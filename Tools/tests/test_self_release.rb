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
    @lane.publish_self_release_package({ prepared: { version: "1.2.0", build_number: 198, source_commit: "abc123-built-commit" } }.merge(options))
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
