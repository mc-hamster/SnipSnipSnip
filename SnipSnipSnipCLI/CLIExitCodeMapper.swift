import Foundation

nonisolated enum CLIExitCodeMapper {
    static func exitCode(for json: String) -> Int32 {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let status = object["status"] as? String else {
            return 0
        }

        if status == "succeeded" {
            return 0
        }

        let error = object["error"] as? [String: Any]
        switch error?["code"] as? String {
        case "invalidRequest":
            return 64
        case "featureUnavailable", "targetUnavailable", "proFeatureRequired",
             "noActiveComposition", "compositionItemNotFound",
             "compositionRequiresMultipleItems", "incompatibleCompositionItems",
             "staleDestination":
            return 69
        case "unsupportedOutput", "outputFailed",
             "unsupportedComparisonOutput", "oversizedOutput":
            return 74
        case "permissionDenied", "confirmationRequired":
            return 77
        case "userCancelled":
            return 130
        default:
            return 70
        }
    }
}
