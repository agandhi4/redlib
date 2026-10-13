/// The build's release identity, "0.1.0 (1)": what a diagnostics screen, log line or bug report
/// names, the app's counterpart of a service's APP_VERSION (observability.md). Read from the
/// Info.plist values Xcode fills from MARKETING_VERSION and CURRENT_PROJECT_VERSION (project.yml).
struct AppVersion: Equatable, Sendable, CustomStringConvertible {
    let marketing: String?
    let build: String?

    /// Missing or empty values stay nil rather than becoming "", so a misconfigured build is
    /// visible as "unknown" instead of a blank.
    init(info: [String: Any]) {
        marketing = Self.nonEmpty(info["CFBundleShortVersionString"])
        build = Self.nonEmpty(info["CFBundleVersion"])
    }

    var description: String {
        switch (marketing, build) {
        case (let marketing?, let build?): "\(marketing) (\(build))"
        case (let marketing?, nil): marketing
        case (nil, let build?): "unknown (\(build))"
        case (nil, nil): "unknown"
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
