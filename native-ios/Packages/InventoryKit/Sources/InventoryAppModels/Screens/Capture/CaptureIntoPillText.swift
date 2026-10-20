extension CaptureIntoPlace {
    /// The Into pill's words beside its pip and tape (RN `LocationLine size="inline"` in the
    /// `IntoPill`): "Garage › Tool chest". An unnamed container is its tape alone, so the words
    /// end at the space: "Garage ›" (RN `labelOf` with the tape shown).
    public var pillLine: String {
        guard let label = PlaceRowText.locationContainerLabel(self, showsTape: true) else { return "\(spaceName) ›" }
        return "\(spaceName) › \(label)"
    }
}
