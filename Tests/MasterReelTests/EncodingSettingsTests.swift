import AVFoundation
import Testing
import VideoToolbox
@testable import MasterReel

struct EncodingSettingsTests {
    @Test func 拡張子からコンテナ形式を決める() {
        #expect(outputFileType(forPathExtension: "mov") == .mov)
        #expect(outputFileType(forPathExtension: "MP4") == .mp4)
        #expect(outputFileType(forPathExtension: "m4v") == .m4v)
        #expect(outputFileType(forPathExtension: "mkv") == nil)
        #expect(outputFileType(forPathExtension: "") == nil)
    }

    @Test func HEVCのMain10で指定サイズに書き出す() {
        let settings = videoOutputSettings(width: 3392, height: 1920)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect(settings[AVVideoWidthKey] as? Int == 3392)
        #expect(settings[AVVideoHeightKey] as? Int == 1920)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    }
}
