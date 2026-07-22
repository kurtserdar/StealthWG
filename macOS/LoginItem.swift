import ServiceManagement

/// Wraps the "launch at login" registration for the app (macOS 13+ SMAppService).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the app as a login item.
    static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
