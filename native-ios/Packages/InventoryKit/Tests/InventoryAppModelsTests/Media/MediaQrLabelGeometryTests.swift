import Testing
@testable import InventoryAppModels

@Suite("QrLabelGeometry (QrCard.tsx sizing, labelImage.ts picture)")
struct MediaQrLabelGeometryTests {
    @Test(
        "the card keeps 220 pt of modules on every iPhone and shrinks on a narrow window",
        arguments: [
            (393.0, 220.0, 252.0),
            (375.0, 220.0, 252.0),
            (440.0, 220.0, 252.0),
            (334.0, 220.0, 252.0),
            (333.0, 219.0, 251.0),
            (320.0, 206.0, 238.0),
            (200.0, 120.0, 152.0),
            (0.0, 120.0, 152.0),
        ]
    )
    func cardSize(window: Double, modules: Double, size: Double) {
        let card = QrLabelGeometry.card(windowWidth: window)
        #expect(card.modules == modules)
        #expect(card.size == size)
    }

    @Test("the offered width is the window less the two gutters")
    func availableWidth() {
        #expect(QrLabelGeometry.card(availableWidth: 393 - 32) == QrLabelGeometry.card(windowWidth: 393))
        #expect(QrLabelGeometry.card(availableWidth: 288) == QrLabelGeometry.card(windowWidth: 320))
    }

    @Test("the quiet zone is 16 pt of the code's side, 16/252 at the standard size")
    func quietRatio() {
        let card = QrLabelGeometry.card(windowWidth: 393)
        #expect(card.quietRatio == 16.0 / 252.0)
        #expect(card.size - card.modules == 2 * QrLabelGeometry.quietZone)
    }

    @Test(
        "the 1024 px picture keeps the card's margin ratio (about 65 px at the standard size)",
        arguments: [(252.0, 65), (238.0, 69), (152.0, 108)]
    )
    func pictureMargin(cardSize: Double, margin: Int) {
        #expect(QrLabelGeometry.pictureMargin(cardSize: cardSize) == margin)
    }

    @Test("a degenerate card size gives no margin rather than a crash")
    func degenerateMargin() {
        #expect(QrLabelGeometry.pictureMargin(cardSize: 0) == 0)
        #expect(QrLabelGeometry.pictureMargin(cardSize: .infinity) == 0)
        #expect(QrLabelGeometry.picturePixels == 1024)
    }
}

@Suite("QrLabelPictureFile (labelImage.ts writeLabelPicture)")
struct MediaQrLabelPictureFileTests {
    @Test(
        "keeps ASCII letters, digits and hyphens of the short code",
        arguments: [
            ("CAB-J92R", "label-CAB-J92R.png"),
            ("drw-7k2m", "label-drw-7k2m.png"),
            ("AB C/1.2", "label-ABC12.png"),
            ("\u{00C9}T\u{00C9}-9", "label-T-9.png"),
            ("📦-X", "label--X.png"),
            ("", "label-label.png"),
            ("/ .", "label-label.png"),
        ]
    )
    func name(shortCode: String, expected: String) {
        #expect(QrLabelPictureFile.name(shortCode: shortCode) == expected)
    }
}

@Suite("CameraZoomBaseline (expo-camera patch zoom baseline)")
struct MediaCameraZoomBaselineTests {
    @Test("a triple camera starts on its wide lens, the first switch-over factor")
    func virtualDevice() {
        #expect(CameraZoomBaseline.factor(switchOverFactors: [2, 6], minAvailable: 1, maxAvailable: 123) == 2)
        #expect(CameraZoomBaseline.factor(switchOverFactors: [3], minAvailable: 1, maxAvailable: 15) == 3)
    }

    @Test("a single lens stays at 1×")
    func singleLens() {
        #expect(CameraZoomBaseline.factor(switchOverFactors: [], minAvailable: 1, maxAvailable: 16) == 1)
    }

    @Test("the factor stays inside what the device allows")
    func clamped() {
        #expect(CameraZoomBaseline.factor(switchOverFactors: [2], minAvailable: 1, maxAvailable: 1.5) == 1.5)
        #expect(CameraZoomBaseline.factor(switchOverFactors: [], minAvailable: 1.2, maxAvailable: 4) == 1.2)
        #expect(CameraZoomBaseline.factor(switchOverFactors: [0, -1], minAvailable: 0, maxAvailable: .nan) == 1)
    }
}
