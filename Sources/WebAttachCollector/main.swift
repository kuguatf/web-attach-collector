import AppKit

let application = NSApplication.shared
let delegate = AppDelegate(arguments: CommandLine.arguments)
application.delegate = delegate
application.run()
