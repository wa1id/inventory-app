import Foundation
import Testing
@testable import Inventory

@Test func appModuleLoads() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
