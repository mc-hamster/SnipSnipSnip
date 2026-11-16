import Foundation
import XCTest
@testable import SnipSnipSnip

final class AutomationSampleScriptTests: XCTestCase {
    /// Run the actual shell samples with transport spies so every checked-in
    /// argument/URL reaches the production parsers without capturing the desktop.
    func testEveryShellSampleProducesAValidAutomationRequest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AutomationSampleScripts-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let argumentsURL = temporary.appendingPathComponent("arguments.json")
        let spy = """
        #!/usr/bin/env python3
        import json, os, sys
        with open(os.environ['SSS_SAMPLE_ARGUMENTS'], 'w') as output:
            json.dump(sys.argv[1:], output)
        print('{"status":"succeeded","payload":{"presets":{"_0":[]}}}')
        """
        for name in ["snipsnipsnipctl", "open"] {
            let url = temporary.appendingPathComponent(name)
            try spy.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        var count = 0
        for surface in ["cli", "url"] {
            let samples = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Docs/Automation/SampleScripts/\(surface)"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "sh" }
            for sample in samples {
                try? FileManager.default.removeItem(at: argumentsURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [sample.path]
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = temporary.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
                environment["SSSCTL"] = temporary.appendingPathComponent("snipsnipsnipctl").path
                environment["SSS_SAMPLE_ARGUMENTS"] = argumentsURL.path
                environment["SSS_URL_SCHEME"] = AppImportURL.scheme
                environment["OUTPUT_DIR"] = temporary.appendingPathComponent("Space & Unicode é").path
                environment["PRESET_NAME"] = "A & B / é"
                process.environment = environment
                process.standardOutput = Pipe()
                let errors = Pipe()
                process.standardError = errors
                try process.run()
                process.waitUntilExit()
                let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, sample.lastPathComponent + ": " + diagnostic)
                let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: argumentsURL))
                let request: AutomationRequest?
                if surface == "cli" {
                    request = AutomationCLIParser.parse(values).request
                } else {
                    request = values.first.flatMap(URL.init(string:)).flatMap(AutomationURLRouter.request(from:))
                }
                XCTAssertNotNil(request, sample.path)
                XCTAssertNil(request?.validationError, sample.path)
                count += 1
            }
        }
        XCTAssertEqual(count, 49)
    }
}
