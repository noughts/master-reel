import AppKit

/// メニューバーの歯車（ScriptMonitor）に進捗を出す（副作用）。
/// ScriptMonitor は、カテゴリが NSProgressScriptProgressCategory の公開された進捗を購読して、
/// 題名・説明・割合と中止ボタンを表示する。キーの名前は公開ヘッダーにないため、文字列で指定する。
/// 中止ボタンが押されると、返した進捗の isCancelled が true になる。
@MainActor
func publishMenuBarProgress(title: String, description: String) -> Progress {
    let progress = Progress(totalUnitCount: 1000)
    progress.setUserInfoObject("NSProgressScriptProgressCategory", forKey: ProgressUserInfoKey("NSProgressCategoryKey"))
    progress.setUserInfoObject(title, forKey: ProgressUserInfoKey("NSProgressScriptTitleKey"))
    progress.localizedDescription = description
    progress.localizedAdditionalDescription = "準備中"
    progress.publish()
    launchScriptMonitor()
    return progress
}

/// メニューバーの進捗を、処理済みの割合と経過時間で更新する（副作用）。
func updateMenuBarProgress(_ progress: Progress, fraction: Double, elapsed: Double) {
    progress.completedUnitCount = Int64(fraction * Double(progress.totalUnitCount))
    progress.localizedAdditionalDescription = menuBarProgressDetail(fraction: fraction, elapsed: elapsed)
}

/// ScriptMonitor が動いていなければ、前面に出さずに起動する（副作用）。
/// 表示する進捗がなくなると自分で終了するため、進捗を出すたびに確かめる。
@MainActor
private func launchScriptMonitor() {
    let bundleIdentifier = "com.apple.ScriptMonitor"
    guard
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
}
