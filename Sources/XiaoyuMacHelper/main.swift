import AppKit

let launchMode = LaunchMode.current()
let instanceLock = SingleInstanceLock()
guard instanceLock.acquireOrNotifyRunningInstance(shouldNotifyRunningInstance: launchMode.notifiesRunningInstance) else {
    exit(0)
}

let app = NSApplication.shared
let delegate = XiaoyuMacHelperApp(instanceLock: instanceLock, launchMode: launchMode)
app.delegate = delegate
app.run()
