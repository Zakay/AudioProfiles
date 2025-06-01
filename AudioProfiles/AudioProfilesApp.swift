import SwiftUI

@main
struct AudioProfilesApp: App {
  // Hook into AppKit's lifecycle
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    Settings {
      // Invisible settings window - the app runs from the menu bar
      EmptyView()
    }
  }
}
