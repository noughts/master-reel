import Foundation

/// 標準エラーに状態を表示する（標準出力は使わない）。
func printStatus(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

do {
    switch try parseArguments(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(usage)
    case let .upscale(input, output):
        let start = ContinuousClock.now
        try await upscaleVideo(input: URL(filePath: input), output: URL(filePath: output))
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        printStatus("完了しました: \(output)（\(formatDuration(elapsed))）")
    }
} catch let error as UsageError {
    printStatus("エラー: \(error.message)\n\n\(usage)")
    exit(EX_USAGE)
} catch {
    printStatus("エラー: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
