import Foundation

nonisolated protocol ProUpdateReleaseFetching {
    func releaseData(from url: URL) async throws -> Data
}

extension URLSession: ProUpdateReleaseFetching {
    func releaseData(from url: URL) async throws -> Data {
        let (data, response) = try await data(from: url, delegate: nil)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

nonisolated struct ProUpdateVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ string: String) {
        let pattern = #"(?<!\d)(\d+(?:\.\d+){0,3})(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = expression.firstMatch(in: string, range: range),
              let matchRange = Range(match.range(at: 1), in: string) else {
            return nil
        }

        let parsedComponents = string[matchRange].split(separator: ".").compactMap { Int($0) }
        guard !parsedComponents.isEmpty else {
            return nil
        }

        self.components = parsedComponents
    }

    static func == (lhs: ProUpdateVersion, rhs: ProUpdateVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: ProUpdateVersion, rhs: ProUpdateVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)

        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0

            if left != right {
                return left < right
            }
        }

        return false
    }
}

nonisolated struct ProUpdateRelease: Equatable {
    let version: ProUpdateVersion
    let buildNumber: Int?
    let displayVersion: String
    let name: String
    let pageURL: URL
}

nonisolated struct ProUpdateCheckResult: Equatable {
    let currentVersion: ProUpdateVersion
    let currentBuildNumber: Int?
    let currentDisplayVersion: String
    let latestRelease: ProUpdateRelease

    var updateIsAvailable: Bool {
        if currentVersion != latestRelease.version {
            return currentVersion < latestRelease.version
        }
        guard let currentBuildNumber, let latestBuildNumber = latestRelease.buildNumber else {
            return false
        }
        return currentBuildNumber < latestBuildNumber
    }
}

nonisolated enum ProUpdateChecker {
    enum CheckError: Error, Equatable {
        case missingCurrentVersion
        case missingCurrentBuildNumber
        case missingReleaseVersion
    }

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
        }
    }

    static func checkCurrentBuild(
        fetcher: ProUpdateReleaseFetching,
        endpoint: URL = AppLinks.proLatestGitHubReleaseAPI,
        bundle: Bundle = .main
    ) async throws -> ProUpdateCheckResult {
        let currentVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let buildNumber = Int(buildString), buildNumber > 0 else {
            throw CheckError.missingCurrentBuildNumber
        }
        return try await check(
            currentVersionString: currentVersionString,
            currentBuildNumber: buildNumber,
            fetcher: fetcher,
            endpoint: endpoint
        )
    }

    static func check(
        currentVersionString: String,
        currentBuildNumber: Int? = nil,
        fetcher: ProUpdateReleaseFetching,
        endpoint: URL = AppLinks.proLatestGitHubReleaseAPI
    ) async throws -> ProUpdateCheckResult {
        guard let currentVersion = ProUpdateVersion(currentVersionString) else {
            throw CheckError.missingCurrentVersion
        }

        let data = try await fetcher.releaseData(from: endpoint)
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let releaseName = response.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let releaseVersionSource = [response.tagName, releaseName].compactMap { $0 }.joined(separator: " ")

        guard let releaseVersion = ProUpdateVersion(releaseVersionSource) else {
            throw CheckError.missingReleaseVersion
        }

        let latestRelease = ProUpdateRelease(
            version: releaseVersion,
            buildNumber: releaseBuildNumber(tag: response.tagName, name: releaseName),
            displayVersion: response.tagName,
            name: releaseName?.isEmpty == false ? releaseName! : response.tagName,
            pageURL: response.htmlURL
        )

        return ProUpdateCheckResult(
            currentVersion: currentVersion,
            currentBuildNumber: currentBuildNumber,
            currentDisplayVersion: currentBuildNumber.map { "\(currentVersionString) (\($0))" } ?? currentVersionString,
            latestRelease: latestRelease
        )
    }

    /// Published Pro tags carry the build separately from the marketing version.
    /// Older releases may carry it only in the conventional title's parentheses.
    private static func releaseBuildNumber(tag: String, name: String?) -> Int? {
        for (source, pattern) in [
            (tag, #"^v\d+\.\d+\.\d+-(?:self|beta)\.([1-9]\d*)$"#),
            (name ?? "", #"\(([1-9]\d*)\)"#)
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source),
                  let build = Int(source[range]) else { continue }
            return build
        }
        return nil
    }
}
