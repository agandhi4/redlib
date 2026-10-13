import Testing

@testable import __PASCAL_NAME__

@Suite("AppVersion")
struct AppVersionTests {
    @Test(arguments: [
        (["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"], "1.2.0 (42)"),
        (["CFBundleShortVersionString": "1.2.0"], "1.2.0"),
        (["CFBundleVersion": "42"], "unknown (42)"),
        (["CFBundleShortVersionString": "", "CFBundleVersion": ""], "unknown"),
        ([:], "unknown"),
    ])
    func describes(info: [String: String], expected: String) {
        #expect(AppVersion(info: info).description == expected)
    }
}
