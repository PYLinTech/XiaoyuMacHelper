import Foundation

let appIdentifier = "local.xiaoyu-mac-helper"
let loginItemArgument = "--login-item"
let showControlWindowNotification = Notification.Name("\(appIdentifier).show-control-window")
let capsLockIndicatorEnabledKey = "CapsLockIndicatorEnabled"
let capsLockIndicatorClickToDisableEnabledKey = "CapsLockIndicatorClickToDisableEnabled"
let selectionToolbarEnabledKey = "SelectionToolbarEnabled"
let selectionToolbarCopyEnabledKey = "SelectionToolbarCopyEnabled"
let selectionToolbarPasteEnabledKey = "SelectionToolbarPasteEnabled"
let selectionToolbarSearchEnabledKey = "SelectionToolbarSearchEnabled"
let selectionToolbarScreenshotEnabledKey = "SelectionToolbarScreenshotEnabled"
let selectionToolbarOrderKey = "SelectionToolbarOrder"
let searchURLTemplateKey = "SearchURLTemplate"
let screenshotSaveDirectoryKey = "ScreenshotSaveDirectory"
let screenshotCopiesToClipboardKey = "ScreenshotCopiesToClipboard"
let screenshotSelectsRegionKey = "ScreenshotSelectsRegion"
let activeVisionEnabledKey = "ActiveVisionEnabled"
let activeVisionPreventDisplaySleepOnGazeKey = "ActiveVisionPreventDisplaySleepOnGaze"
let activeVisionPreventDisplaySleepOnFacingKey = "ActiveVisionPreventDisplaySleepOnFacing"
let activeVisionNotifyWhenExtendingDisplaySleepKey = "ActiveVisionNotifyWhenExtendingDisplaySleep"
let activeVisionLeadTimeBeforeDisplaySleep: TimeInterval = 30
let selectionToolbarDefaultOffMigrationKey = "SelectionToolbarDefaultOffMigrationDone"

func defaultScreenshotDirectoryURL() -> URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
}
