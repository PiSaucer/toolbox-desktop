import AppKit

// This project has no storyboard: create the one application delegate here,
// then hand control to AppKit's normal event loop.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
