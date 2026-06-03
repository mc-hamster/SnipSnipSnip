import Foundation

nonisolated enum PackageTemporaryDirectoryJanitor {
    static func cleanupStalePackageTemporaryDirectories(
        fileManager: FileManager = .default,
        in directoryURL: URL? = nil
    ) throws {
        try removeDirectories(
            matchingPrefixes: [
                SSSDocumentPackage.temporaryDirectoryPrefix,
                SSSVideoDocumentPackage.temporaryDirectoryPrefix
            ],
            fileManager: fileManager,
            in: directoryURL ?? fileManager.temporaryDirectory
        )
    }

    static func removeDirectories(
        matchingPrefixes prefixes: [String],
        fileManager: FileManager = .default,
        in directoryURL: URL
    ) throws {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .nameKey]
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        for candidateURL in contents {
            let values = try candidateURL.resourceValues(forKeys: resourceKeys)
            let name = values.name ?? candidateURL.lastPathComponent

            if values.isDirectory == true,
               prefixes.contains(where: { name.hasPrefix($0) }) {
                try? fileManager.removeItem(at: candidateURL)
            }
        }
    }
}
