/// コマンドライン引数から決まる実行内容。
enum Command: Equatable {
    case help
    case upscale(input: String, output: String)
}

/// 引数の誤り。メッセージはそのままユーザーに表示する。
struct UsageError: Error, Equatable {
    let message: String
}

let usage = """
    使い方: video-enhancer <入力動画> <出力動画>

    VideoToolbox の VTSuperResolutionScaler で動画を超解像します。
    出力は HEVC で、音声トラックは再エンコードせずにコピーします。

    入力の上限: 1920x1080（縦長の動画は回転情報付きの横長で保存されているもののみ）
    出力形式: 出力パスの拡張子（.mov / .mp4 / .m4v）で決まります

    オプション:
      -h, --help  このヘルプを表示
    """

/// 引数（実行ファイル名を除く）を解析する。
func parseArguments(_ arguments: [String]) throws(UsageError) -> Command {
    if arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
        return .help
    }
    if let option = arguments.first(where: { $0.hasPrefix("-") }) {
        throw UsageError(message: "不明なオプションです: \(option)")
    }
    guard arguments.count == 2 else {
        throw UsageError(message: "入力動画と出力動画のパスを1つずつ指定してください。")
    }
    return .upscale(input: arguments[0], output: arguments[1])
}
