import AppKit

// 自更新辅助进程模式：主进程已退出，这里只做内容级替换并拉起新版本，不抢实例锁。
if let updateArgs = UpdateInstaller.parsePerformUpdateArguments() {
    exit(UpdateInstaller.performUpdate(updateArgs))
}

let launchMode = LaunchMode.current()
let instanceLock = SingleInstanceLock()
guard instanceLock.acquireOrNotifyRunningInstance(shouldNotifyRunningInstance: launchMode.notifiesRunningInstance) else {
    exit(0)
}

let app = NSApplication.shared
let delegate = XiaoyuMacHelperApp(instanceLock: instanceLock, launchMode: launchMode)
app.delegate = delegate
app.run()
