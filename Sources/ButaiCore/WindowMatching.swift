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
    public static func match(item: PresetItem, window: DiscoveredWindow) -> WindowMatch {
        var score = 0
        let bundleMatched = item.applicationBundleIdentifier == nil ||
            item.applicationBundleIdentifier == window.bundleIdentifier

        if item.applicationBundleIdentifier != nil {
            score += bundleMatched ? 50 : -100
        }

        for rule in item.matchRules where ruleMatches(rule, window: window) {
            score += max(rule.weight, 0)
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
            return window.title.range(of: rule.value, options: .regularExpression) != nil
        case .documentURL:
            return window.documentURL == rule.value
        case .resourcePath:
            return window.resourcePath == rule.value
        case .role:
            return window.role == rule.value
        case .subrole:
            return window.subrole == rule.value
        }
    }
}
