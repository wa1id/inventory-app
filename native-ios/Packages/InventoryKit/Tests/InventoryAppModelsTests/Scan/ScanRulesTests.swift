import InventoryCore
import Testing
@testable import InventoryAppModels

@Suite("ScanRules.labelFor (scanRules.test.ts)")
struct ScanRulesLabelForTests {
    @Test("uses the name, or else the code on the label")
    func labelFor() {
        #expect(ScanRules.labelFor(name: "Tool chest", shortCode: "CAB-J92R") == "Tool chest")
        #expect(ScanRules.labelFor(name: nil, shortCode: "BOX-7K2M") == "BOX-7K2M")
        #expect(ScanRules.labelFor(name: "   ", shortCode: "BOX-7K2M") == "BOX-7K2M")
        // The name as stored, untrimmed.
        #expect(ScanRules.labelFor(name: " Tool chest ", shortCode: "CAB-J92R") == " Tool chest ")
        #expect(ScanRules.labelFor(ScanTestData.option(name: nil, shortCode: "BIN-4F2A")) == "BIN-4F2A")
        #expect(ScanRules.labelFor(ScanTestData.container()) == "Tool chest")
    }
}

@Suite("ScanRules.tokenParam (scanRules.test.ts)")
struct ScanRulesTokenParamTests {
    @Test("reads one token from the route")
    func readsOne() {
        #expect(ScanRules.tokenParam(ScanTestData.token) == ScanTestData.token)
        #expect(ScanRules.tokenParam(" \(ScanTestData.token) ") == ScanTestData.token)
    }

    @Test("keeps the first of a repeated parameter")
    func keepsFirst() {
        #expect(ScanRules.tokenParam([ScanTestData.token, ScanTestData.otherToken]) == ScanTestData.token)
    }

    @Test("is empty when there is nothing to read")
    func empty() {
        #expect(ScanRules.tokenParam(nil as String?) == "")
        #expect(ScanRules.tokenParam([String]()) == "")
    }
}

@Suite("ScanRules.planBind (scanRules.test.ts)")
struct ScanRulesPlanBindTests {
    @Test("links straight away when the container has no label")
    func noLabel() {
        #expect(ScanRules.planBind(existing: nil, token: ScanTestData.token, label: "Tool chest") == ScanBindPlan(write: true, confirm: nil))
    }

    @Test("asks before retiring the sticker the container already has")
    func asksFirst() {
        let plan = ScanRules.planBind(existing: ScanTestData.binding(ScanTestData.otherToken), token: ScanTestData.token, label: "Tool chest")
        #expect(plan.write)
        #expect(plan.confirm == ConfirmOptions(
            title: "Replace the label on Tool chest?",
            body: "Tool chest already has a label. Its old sticker will stop opening it.",
            confirmLabel: "Replace"
        ))
        // RN's confirm(): Cancel, then a destructive Replace.
        #expect(plan.confirm?.cancelLabel == "Cancel")
        #expect(plan.confirm?.destructive == true)
    }

    @Test("writes nothing when this label was linked to it meanwhile")
    func linkedMeanwhile() {
        #expect(ScanRules.planBind(existing: ScanTestData.binding(ScanTestData.token.uppercased()), token: ScanTestData.token, label: "Tool chest") == ScanBindPlan(write: false, confirm: nil))
    }

    @Test("never says \"Move this label?\" for a replacement")
    func neverMove() {
        let plan = ScanRules.planBind(existingToken: ScanTestData.otherToken, token: ScanTestData.token, label: "BOX-7K2M")
        #expect(plan.confirm?.title.lowercased().contains("move") == false)
    }
}

@Suite("ScanRules.linkFailureMessage (scanRules.test.ts)")
struct ScanRulesLinkFailureTests {
    @Test("says to check the connection when the home server did not answer")
    func offline() {
        #expect(ScanRules.linkFailureMessage(HouseholdHttpError(status: 0, code: "offline")) == "The label was not linked. Check the connection and try again.")
        #expect(ScanRules.linkFailureMessage(HouseholdHttpError(status: 530, code: "http_530")) == "The label was not linked. Check the connection and try again.")
    }

    @Test("says the container is gone when it was deleted elsewhere")
    func gone() {
        #expect(ScanRules.linkFailureMessage(HouseholdHttpError(status: 404, code: "not_found")) == "That container is not in the household any more. Choose another one.")
    }

    @Test("never shows a raw code or message")
    func noRawCode() {
        struct SQLiteConstraint: Error {}
        #expect(ScanRules.linkFailureMessage(SQLiteConstraint()) == "The label was not linked. Try again.")
        #expect(!ScanRules.linkFailureMessage(HouseholdHttpError(status: 500, code: "http_500")).contains("http_"))
    }
}
