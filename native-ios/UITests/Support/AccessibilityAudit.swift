import XCTest

/// An audit issue a screen's test lets through, with the reason written next to the test.
struct AuditException {
    /// What else an exception can be narrowed by (`AuditException(_:_:because:)`). Every field
    /// that is set must match.
    struct Match {
        /// The issue's description starts with this ("Contrast nearly passed"), so the same
        /// element's worse issue ("Contrast failed") still fails.
        var description: String?
        /// The element's identifier or label is exactly this.
        var element: String?
        /// The element's label starts with this.
        var labelPrefix: String?
        /// The element's whole label matches this regular expression (a short code on a tape).
        var labelPattern: String?
        /// The element's label passes this test (what a regular expression cannot say simply,
        /// such as "only emoji").
        var labelTest: (@Sendable (String) -> Bool)?
        /// The element is of this type (a search field, a text field).
        var elementType: XCUIElement.ElementType?
        /// The element's frame starts at least this far down the window, in points.
        var minY: CGFloat?
        /// The audit attached the issue to no element at all.
        var withoutElement = false
    }

    let type: XCUIAccessibilityAuditType
    /// The identifier or label of the element it covers; nil covers every element.
    let element: String?
    let reason: String
    var match = Match()

    init(_ type: XCUIAccessibilityAuditType, element: String? = nil, because reason: String) {
        self.type = type
        self.element = element
        self.reason = reason
    }

    /// An exception narrowed by `match`.
    init(_ type: XCUIAccessibilityAuditType, _ match: Match, because reason: String) {
        self.type = type
        self.element = match.element
        self.reason = reason
        self.match = match
    }

    /// Whether this exception lets `issue` through.
    func covers(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard type == issue.auditType else { return false }
        if let description = match.description, !issue.compactDescription.hasPrefix(description) { return false }
        if match.withoutElement { return issue.element == nil }
        let identifier = issue.element?.identifier ?? ""
        let label = issue.element?.label ?? ""
        if let prefix = match.labelPrefix, !label.hasPrefix(prefix) { return false }
        if let pattern = match.labelPattern {
            guard let regex = try? Regex(pattern), label.wholeMatch(of: regex) != nil else { return false }
        }
        if let test = match.labelTest, !test(label) { return false }
        if let elementType = match.elementType, issue.element?.elementType != elementType { return false }
        if let minY = match.minY {
            guard let frame = issue.element?.frame, frame.minY >= minY else { return false }
        }
        return element == nil || element == identifier || element == label
    }
}

extension XCUIApplication {
    /// Runs Xcode's accessibility audit (contrast, element detection, hit regions, descriptions,
    /// clipped text, Dynamic Type, traits) on what the app shows now and fails the test on each
    /// issue `exceptions` doesn't cover. With `reportOnly` it never fails and prints every issue
    /// as an "[audit]" line instead, for surveys.
    func auditScreen(
        _ name: String,
        types: XCUIAccessibilityAuditType = .all,
        except exceptions: [AuditException] = [],
        reportOnly: Bool = false
    ) throws {
        try performAccessibilityAudit(for: types) { issue in
            let identifier = issue.element?.identifier ?? ""
            let label = issue.element?.label ?? ""
            let covered = exceptions.contains { $0.covers(issue) }
            if !covered {
                let frame = issue.element.map { " at \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""
                print("[audit] \(name): \(Self.auditTypeName(issue.auditType)): \(issue.compactDescription) (id \"\(identifier)\", label \"\(label)\"\(frame))")
            }
            return covered || reportOnly
        }
    }

    private static func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "type \(type.rawValue)"
        }
    }
}
