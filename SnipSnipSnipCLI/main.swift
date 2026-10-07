import Foundation

// Keep command parsing in the app's shared AutomationCLIParser. Passing the
// original argument array also preserves privacy, interaction policy, quoting,
// and newly supported options without a second AppleScript command generator.
let arguments = Array(CommandLine.arguments.dropFirst())
let data = try JSONSerialization.data(withJSONObject: arguments)
let json = String(decoding: data, as: UTF8.self)
let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
let source = """
with timeout of 300 seconds
    tell application id "com.oontz.SnipSnipSnip"
        execute command line argumentsJSON "\(escaped)"
    end tell
end timeout
"""
var error: NSDictionary?
guard let script = NSAppleScript(source: source),
      let result = script.executeAndReturnError(&error).stringValue else {
    if let error {
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    }
    exit((error?[NSAppleScript.errorNumber] as? Int) == -1743 ? 77 : 70)
}
print(result)
exit(CLIExitCodeMapper.exitCode(for: result))
