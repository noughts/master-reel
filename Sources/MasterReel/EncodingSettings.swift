import AVFoundation
import VideoToolbox

/// 出力パスの拡張子からコンテナ形式を決める。対応しない拡張子なら nil。
func outputFileType(forPathExtension pathExtension: String) -> AVFileType? {
    switch pathExtension.lowercased() {
    case "mov": .mov
    case "mp4": .mp4
    case "m4v": .m4v
    default: nil
    }
}

/// 超解像後の映像を HEVC で書き出すための AVAssetWriterInput 設定。
/// 超解像の出力は 16bit 浮動小数なので、SDR・HDR とも階調を保てる Main10 で書き出す。
/// 品質 0.65 は、0.85 と見分けがつかない画質のままファイルサイズを約 1/10 にできる値（実測）。
/// 色空間は設定せず、各フレームに付いた色情報からエンコーダーが決める。
func videoOutputSettings(width: Int, height: Int) -> [String: Any] {
    [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoQualityKey: 0.65,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
        ],
    ]
}
