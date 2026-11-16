import VideoToolbox

/// コマンドライン引数から決まる実行内容。
enum Command: Equatable {
    case help
    case upscale(input: String, output: String, inputType: VTSuperResolutionScalerConfiguration.InputType, interpolate: Bool)
}

/// 引数の誤り。メッセージはそのままユーザーに表示する。
struct UsageError: Error, Equatable {
    let message: String
}

let usage = """
    使い方: master-reel <入力動画> <出力動画>

    VideoToolbox の VTSuperResolutionScaler で動画を超解像します。
    --interpolate を付けると、VTFrameRateConversion でフレームレートも 2 倍にします。
    出力は HEVC で、音声トラックは再エンコードせずにコピーします。

    入力の上限: 1920x1920（--video 指定時は 1920x1080）
    出力形式: 出力パスの拡張子（.mov / .mp4 / .m4v）で決まります

    オプション:
      --video        動画モードで超解像する。前フレームを参照してフレーム間のちらつきを
                     抑える代わりに、既定の画像モードより細部が控えめになる
      --interpolate  超解像したフレームの間をフレーム補間で埋め、フレームレートを 2 倍にする。
                     超解像後の解像度が 8192x4320 以下（入力の高さが 1080 以下）のときだけ使える
      -h, --help     このヘルプを表示
    """

/// 引数（実行ファイル名を除く）を解析する。
func parseArguments(_ arguments: [String]) throws(UsageError) -> Command {
    if arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
        return .help
    }
    let flags: Set = ["--video", "--interpolate"]
    let paths = arguments.filter { !flags.contains($0) }
    if let option = paths.first(where: { $0.hasPrefix("-") }) {
        throw UsageError(message: "不明なオプションです: \(option)")
    }
    guard paths.count == 2 else {
        throw UsageError(message: "入力動画と出力動画のパスを1つずつ指定してください。")
    }
    return .upscale(
        input: paths[0],
        output: paths[1],
        inputType: arguments.contains("--video") ? .video : .image,
        interpolate: arguments.contains("--interpolate")
    )
}
