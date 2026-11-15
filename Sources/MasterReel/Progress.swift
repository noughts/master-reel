import Foundation

/// 進捗表示の1行を作る。
/// - Parameters:
///   - position: 最後に処理したフレームの時刻（秒）
///   - duration: 動画の長さ（秒）
///   - frames: 処理済みフレーム数
///   - elapsed: 処理開始からの経過時間（秒）
func progressLine(position: Double, duration: Double, frames: Int, elapsed: Double) -> String {
    let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
    let percent = String(format: "%5.1f%%", fraction * 100)
    let fps = elapsed > 0 ? String(format: "%.1f fps", Double(frames) / elapsed) : "- fps"
    var line = "超解像中 \(percent)  \(frames) フレーム  \(fps)"
    if fraction > 0, fraction < 1 {
        line += "  残り約 \(formatDuration(elapsed * (1 - fraction) / fraction))"
    }
    return line
}

/// 秒数を「m:ss」または「h:mm:ss」にする。
func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}
