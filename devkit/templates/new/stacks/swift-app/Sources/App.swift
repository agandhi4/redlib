import SwiftUI

@main
struct __PASCAL_NAME__App: App {
    var body: some Scene {
        WindowGroup {
            ContentView(version: AppVersion(info: Bundle.main.infoDictionary ?? [:]))
        }
    }
}
