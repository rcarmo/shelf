import Foundation

struct ScriptResult {
    var output: String
    var error: String?

    var succeeded: Bool { error == nil }
}

struct AppleScriptRunner {
    func run(_ source: String) -> ScriptResult {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ScriptResult(output: "", error: "Could not compile AppleScript.")
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            return ScriptResult(output: "", error: message)
        }
        return ScriptResult(output: descriptor.stringValue ?? "", error: nil)
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
