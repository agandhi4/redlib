import SwiftUI

struct ContentView: View {
    let version: AppVersion

    var body: some View {
        VStack(spacing: 8) {
            Text("__NAME__")
                .font(.title)
            // The build identity, so a screenshot or bug report names the exact build.
            Text(version.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView(version: AppVersion(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]))
}
