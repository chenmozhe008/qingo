import AppKit
import Testing
@testable import Qingo

struct AppearanceTests {
    @Test @MainActor func automaticClearsForcedAppearance() {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }

        AppearanceMode.dark.apply()
        #expect(app.appearance?.name == .darkAqua)
        AppearanceMode.system.apply()
        #expect(app.appearance == nil)
        AppearanceMode.light.apply()
        #expect(app.appearance?.name == .aqua)
        AppearanceMode.system.apply()
        #expect(app.appearance == nil)
    }
}
