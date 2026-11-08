# Release policy and source verification shared by Fastlane and offline tests.
require "open3"
require "pathname"
require "tmpdir"

module SelfReleaseSupport
  def self.with_source_snapshot(repository_root:, commit:)
    return yield(repository_root) unless commit

    Dir.mktmpdir("snipsnipsnip-release-source-") do |directory|
      snapshot = File.join(directory, "source")
      [["clone", "--quiet", "--shared", "--no-checkout", "--", repository_root, snapshot],
       ["-C", snapshot, "checkout", "--quiet", "--detach", commit]].each do |arguments|
        _output, errors, status = Open3.capture3("git", *arguments)
        raise "Could not prepare release source snapshot: #{errors.strip}" unless status.success?
      end
      yield snapshot
    end
  end

  # Compare against Git's committed content, allowing only the exact build-number
  # edit this run owns. HEAD alone cannot detect editor saves during a release.
  class PublishSource
    attr_reader :commit

    def initialize(repository_root:, project_path:, commit:)
      @root = File.expand_path(repository_root)
      @commit = commit
      project_file = File.join(File.expand_path(project_path), "project.pbxproj")
      @project_file = Pathname.new(project_file).relative_path_from(Pathname.new(@root)).to_s
      raise "The publishing project must be inside the source repository." if @project_file.start_with?("../")

      @committed_project = git("show", "#{commit}:#{@project_file}").b
      verify!
    end

    def verify!(build_number: nil)
      expected_project = project_contents(build_number)
      changed_files = git("diff", "--name-only", "-z", commit, "--").split("\0")
      allowed_files = build_number ? [@project_file] : []
      unchanged = git("rev-parse", "HEAD").strip == commit &&
                  (changed_files - allowed_files).empty? &&
                  git("ls-files", "--others", "--exclude-standard", "-z").empty? &&
                  File.binread(File.join(@root, @project_file)) == expected_project
      raise "Source changed during release preparation. Commit source changes and rerun before publishing." unless unchanged
      true
    end

    def apply_build_number!(build_number)
      verify!
      File.binwrite(File.join(@root, @project_file), project_contents(build_number))
      verify!(build_number: build_number)
    end

    private

    def project_contents(build_number)
      expected_project = @committed_project
      if build_number
        build = Integer(build_number)
        raise "Build number must be positive." unless build.positive?
        expected_project = expected_project.gsub(/^([ \t]*CURRENT_PROJECT_VERSION = )([^;]+)(;)$/) do
          "#{Regexp.last_match(1)}#{build}#{Regexp.last_match(3)}"
        end
      end
      expected_project
    end

    def git(*arguments)
      output, errors, status = Open3.capture3("git", "-C", @root, *arguments)
      raise "Could not verify publishing source: #{errors.strip}" unless status.success?
      output
    end
  end

  def self.next_build_number(local_build, remote_tags)
    remote_builds = remote_tags.map do |tag|
      match = /\Av\d+\.\d+\.\d+-(?:self|beta)\.([1-9]\d*)\z/.match(tag)
      Integer(match[1], 10) if match
    end.compact
    ([Integer(local_build)] + remote_builds).max + 1
  end

  def self.release_arguments(tag:, asset:, repository:, title:, notes_file:, draft:, prerelease:)
    arguments = ["gh", "release", "create", tag, asset, "--repo", repository,
                 "--verify-tag", "--title", title, "--notes-file", notes_file]
    arguments << "--draft" if draft
    arguments.concat(["--prerelease", "--latest=false"]) if prerelease
    arguments
  end
end
