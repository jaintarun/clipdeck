import Foundation
import ServiceManagement

/// SMAppService is the modern replacement for the deprecated
/// SMLoginItemSetEnabled. Requires macOS 13+, which is our floor.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
