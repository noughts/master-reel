import Foundation

/// 標準エラーに状態を表示する（標準出力は使わない）。
func printStatus(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

do {
    switch try parseArguments(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(usage)
    case let .upscale(input, output, inputType, interpolate):
        let start = ContinuousClock.now
        let inputURL = URL(filePath: input)
        let menuBarProgress = publishMenuBarProgress(
            title: inputURL.lastPathComponent,
            description: interpolate ? "超解像とフレーム補間中" : "超解像中"
        )
        try await upscaleVideo(input: inputURL, output: URL(filePath: output), inputType: inputType, interpolate: interpolate, progress: menuBarProgress)
        menuBarProgress.unpublish()
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        printStatus("完了しました: \(output)（\(formatDuration(elapsed))）")
    }
} catch let error as UsageError {
    printStatus("エラー: \(error.message)\n\n\(usage)")
    exit(EX_USAGE)
} catch UpscaleError.cancelled {
    printStatus(UpscaleError.cancelled.localizedDescription)
    // Ctrl-C で中断したときと同じ終了コードにして、呼び出し側が失敗と区別できるようにする。
    exit(130)
} catch {
    printStatus("エラー: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
