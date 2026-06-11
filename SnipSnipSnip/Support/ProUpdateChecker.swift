import Foundation

nonisolated protocol ProUpdateReleaseFetching {
    func releaseData(from url: URL) async throws -> Data
}

extension URLSession: ProUpdateReleaseFetching {
    func releaseData(from url: URL) async throws -> Data {
        let (data, _) = try await data(from: url, delegate: nil)
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
    let displayVersion: String
    let name: String
    let pageURL: URL
}

nonisolated struct ProUpdateCheckResult: Equatable {
    let currentVersion: ProUpdateVersion
    let currentDisplayVersion: String
    let latestRelease: ProUpdateRelease

    var updateIsAvailable: Bool {
        currentVersion < latestRelease.version
    }
}

nonisolated enum ProUpdateChecker {
    enum CheckError: Error, Equatable {
        case missingCurrentVersion
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
        return try await check(
            currentVersionString: currentVersionString,
            fetcher: fetcher,
            endpoint: endpoint
        )
    }

    static func check(
        currentVersionString: String,
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
            displayVersion: response.tagName,
            name: releaseName?.isEmpty == false ? releaseName! : response.tagName,
            pageURL: response.htmlURL
        )

        return ProUpdateCheckResult(
            currentVersion: currentVersion,
            currentDisplayVersion: currentVersionString,
            latestRelease: latestRelease
        )
    }
}
