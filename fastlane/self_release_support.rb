# Pure release policy shared by Fastlane and its offline regression tests.
module SelfReleaseSupport
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
