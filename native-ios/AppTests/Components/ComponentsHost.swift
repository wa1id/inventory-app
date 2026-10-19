import Darwin
import SwiftUI
import Testing
import UIKit
@testable import Inventory

/// Hosts a SwiftUI view in a window at a fixed width, lays it out and reads back its size and
/// accessibility elements, so the component tests can check that a view renders, fits the width
/// at every text size and says what it should.
@MainActor
enum ComponentsHost {
    struct Element {
        let label: String
        let identifier: String
        let value: String
        let traits: UIAccessibilityTraits
    }

    struct Rendered {
        let size: CGSize
        let elements: [Element]

        func element(identifier: String) -> Element? {
            elements.first { $0.identifier == identifier }
        }

        /// Every element as "label [identifier]", for failure messages.
        var dump: String {
            elements.map { "\($0.label) [\($0.identifier)]" }.joined(separator: "; ")
        }

        func element(label: String) -> Element? {
            elements.first { $0.label == label }
        }
    }

    /// Appearances every component is drawn in.
    struct Appearance: Sendable, CustomTestStringConvertible {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var testDescription: String { "\(scheme == .dark ? "dark" : "light"), \(size)" }

        static let all = [
            Appearance(scheme: .light, size: .large),
            Appearance(scheme: .dark, size: .large),
            Appearance(scheme: .light, size: .accessibility5),
        ]
    }

    /// SwiftUI vends its accessibility elements only to an assistive technology. Test hosts
    /// switch on the automation mode UI tests run in (libAccessibility's
    /// `_AXSSetAutomationEnabled`, test bundle only), so the tests can read the elements.
    private static let accessibilityEnabled: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
        return true
    }()

    /// - Parameter settle: how long the run loop turns before the elements are read (timers such
    ///   as the skeleton's 180 ms wait need longer than a layout pass).
    static func render<V: View>(
        _ view: V,
        width: CGFloat = 390,
        appearance: Appearance = Appearance(scheme: .light, size: .large),
        settle: TimeInterval = 0.15
    ) -> Rendered {
        _ = accessibilityEnabled
        let root = view
            .environment(\.colorScheme, appearance.scheme)
            .environment(\.dynamicTypeSize, appearance.size)
            .environment(\.layoutWindowWidth, width)
            .frame(width: width)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let fitting = host.sizeThatFits(in: CGSize(width: width, height: 20_000))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: max(1, min(fitting.height, 20_000)))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // SwiftUI builds its accessibility nodes after the update that laid the view out.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        // Whatever appeared meanwhile (a delayed skeleton) gets laid out too.
        let settled = host.sizeThatFits(in: CGSize(width: width, height: 20_000))
        if settled.height != fitting.height {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: max(1, min(settled.height, 20_000)))
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        var elements: [Element] = []
        collect(host.view, into: &elements, depth: 0)
        window.isHidden = true
        return Rendered(size: settled, elements: elements)
    }

    /// SwiftUI's accessibility nodes answer `accessibilityIdentifier` without declaring
    /// `UIAccessibilityIdentification`, so it is read by selector.
    /// Hosts the view, then waits `delay` on the main actor so its tasks and timers run (the
    /// skeleton's 180 ms wait), lays it out again and reads it.
    static func renderAfter<V: View>(_ delay: Duration, _ view: V, width: CGFloat = 390) async -> Rendered {
        _ = accessibilityEnabled
        let host = UIHostingController(rootView: view.environment(\.layoutWindowWidth, width).frame(width: width))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: delay)
        let fitting = host.sizeThatFits(in: CGSize(width: width, height: 20_000))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: max(1, min(fitting.height, 20_000)))
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        var elements: [Element] = []
        collect(host.view, into: &elements, depth: 0)
        window.isHidden = true
        return Rendered(size: fitting, elements: elements)
    }

    private static func identifier(of object: NSObject) -> String {
        if let identified = object as? UIAccessibilityIdentification, let identifier = identified.accessibilityIdentifier {
            return identifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    private static func collect(_ object: Any, into elements: inout [Element], depth: Int) {
        guard depth < 60, let object = object as? NSObject else { return }
        if object.isAccessibilityElement {
            elements.append(
                Element(
                    label: object.accessibilityLabel ?? "",
                    identifier: identifier(of: object),
                    value: object.accessibilityValue ?? "",
                    traits: object.accessibilityTraits
                )
            )
        }
        if let children = object.accessibilityElements, !children.isEmpty {
            for child in children { collect(child, into: &elements, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) {
                        collect(child, into: &elements, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &elements, depth: depth + 1) }
        }
    }
}
