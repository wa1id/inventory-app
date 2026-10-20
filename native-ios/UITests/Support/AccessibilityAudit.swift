import XCTest

/// An audit issue a screen's test lets through, with the reason written next to the test.
struct AuditException {
    let type: XCUIAccessibilityAuditType
    /// The identifier or label of the element it covers; nil covers every element.
    let element: String?
    let reason: String

    init(_ type: XCUIAccessibilityAuditType, element: String? = nil, because reason: String) {
        self.type = type
        self.element = element
        self.reason = reason
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
            let covered = exceptions.contains { exception in
                exception.type == issue.auditType
                    && (exception.element == nil || exception.element == identifier || exception.element == label)
            }
            if !covered {
                print("[audit] \(name): \(Self.auditTypeName(issue.auditType)): \(issue.compactDescription) (id \"\(identifier)\", label \"\(label)\")")
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
