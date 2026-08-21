import Foundation

public struct DiscoveredWindow: Equatable, Sendable {
    public var bundleIdentifier: String
    public var title: String
    public var documentURL: String?
    public var resourcePath: String?
    public var role: String?
    public var subrole: String?

    public init(
        bundleIdentifier: String,
        title: String,
        documentURL: String? = nil,
        resourcePath: String? = nil,
        role: String? = nil,
        subrole: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.documentURL = documentURL
        self.resourcePath = resourcePath
        self.role = role
        self.subrole = subrole
    }
}

public struct WindowMatch: Equatable, Sendable {
    public enum Confidence: String, Sendable { case low, medium, high }
    public var score: Int
    public var confidence: Confidence
    public var bundleIdentifierMatched: Bool
}

public enum WindowMatcher {
    public static func minimumAcceptedScore(for item: PresetItem) -> Int {
        item.matchRules.isEmpty && item.resourcePath == nil ? 50 : 75
    }

    public static func isAcceptable(item: PresetItem, match: WindowMatch) -> Bool {
        match.bundleIdentifierMatched && match.score >= minimumAcceptedScore(for: item)
    }

    public static func match(item: PresetItem, window: DiscoveredWindow) -> WindowMatch {
        var score = 0
        let expectedBundleIdentifier = item.applicationBundleIdentifier
            ?? item.matchRules.first(where: { $0.kind == .bundleIdentifier })?.value
        // Never treat an unidentified application as an identity match. A
        // title or URL alone is not safe enough to move another app's window.
        let bundleMatched = expectedBundleIdentifier == window.bundleIdentifier

        if expectedBundleIdentifier != nil {
            score += bundleMatched ? 50 : -100
        }

        for rule in item.matchRules where ruleMatches(rule, window: window) {
            // Persisted configuration is user-editable. Bound individual
            // weights so malformed values cannot overflow Int and crash.
            score += min(max(rule.weight, 0), 100)
        }

        let confidence: WindowMatch.Confidence
        if bundleMatched && score >= 75 {
            confidence = .high
        } else if bundleMatched && score >= 50 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return WindowMatch(score: score, confidence: confidence, bundleIdentifierMatched: bundleMatched)
    }

    private static func ruleMatches(_ rule: WindowMatchRule, window: DiscoveredWindow) -> Bool {
        switch rule.kind {
        case .bundleIdentifier:
            return window.bundleIdentifier == rule.value
        case .titleExact:
            return window.title == rule.value
        case .titlePrefix:
            return window.title.hasPrefix(rule.value)
        case .titleSuffix:
            return window.title.hasSuffix(rule.value)
        case .titleRegex:
            guard regexIsSafe(rule.value), window.title.count <= 512,
                  let expression = try? NSRegularExpression(pattern: rule.value) else { return false }
            let range = NSRange(window.title.startIndex..., in: window.title)
            return expression.firstMatch(in: window.title, range: range) != nil
        case .documentURL:
            return normalizedURLString(window.documentURL) == normalizedURLString(rule.value)
        case .resourcePath:
            return normalizedFilePath(window.resourcePath) == normalizedFilePath(rule.value)
        case .role:
            return window.role == rule.value
        case .subrole:
            return window.subrole == rule.value
        }
    }

    /// Foundation regular expressions have no matching timeout. Keep a small,
    /// conservative subset: repeated groups, backreferences and patterns with
    /// many quantifiers are rejected to avoid catastrophic backtracking.
    private static func regexIsSafe(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 128,
              !pattern.contains("(?") else { return false }
        var escaped = false
        var quantifierCount = 0
        var previous: Character?
        for character in pattern {
            if escaped {
                if character.isNumber { return false }
                escaped = false
                previous = character
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if "*+?{".contains(character) {
                quantifierCount += 1
                if quantifierCount > 2 || previous == ")" ||
                    previous.map({ "*+?}".contains($0) }) == true {
                    return false
                }
            }
            previous = character
        }
        return !escaped
    }

    private static func normalizedFilePath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let path: String
        if let url = URL(string: value), url.isFileURL {
            path = url.path
        } else {
            path = value
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value) else { return value }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80) ||
            (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string
    }
}
