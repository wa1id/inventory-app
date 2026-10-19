/// The back camera's starting zoom (05 §8.1, §8.3; the expo-camera patch).
///
/// The camera service picks the first available of the virtual multi-camera devices (triple,
/// dual wide, dual), then the plain wide-angle camera, so a close subject switches to the
/// ultra-wide lens on its own (the "macro" behaviour of Camera.app). A virtual device starts at
/// its widest lens, so the zoom is set to the first switch-over factor: the wide-angle "1×" view
/// RN showed. There is no pinch zoom (DECISIONS U7).
public enum CameraZoomBaseline {
    /// The starting `videoZoomFactor`: the first `virtualDeviceSwitchOverVideoZoomFactors` value
    /// (2.0 on a triple camera), or 1.0 for a single lens, kept inside what the device allows.
    /// RN computed `minZoom × (maxZoom / minZoom)^zoom` with `zoom = 0`, which is `minZoom`.
    // RN: patches/expo-camera+57.0.3.patch:297-309
    public static func factor(switchOverFactors: [Double], minAvailable: Double, maxAvailable: Double) -> Double {
        let wide = switchOverFactors.first(where: { $0.isFinite && $0 > 0 }) ?? 1
        let low = minAvailable.isFinite && minAvailable > 0 ? minAvailable : 1
        let high = maxAvailable.isFinite ? max(low, maxAvailable) : low
        return min(max(wide, low), high)
    }
}
