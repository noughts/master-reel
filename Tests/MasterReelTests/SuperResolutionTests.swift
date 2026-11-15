import AVFoundation
import Testing
import VideoToolbox
@testable import MasterReel

/// 実際の VideoToolbox・AVFoundation・ファイルを通した統合テスト。
@Suite(.enabled(if: VTSuperResolutionScalerConfiguration.isSupported, "この Mac は超解像に非対応"))
struct SuperResolutionTests {
    @Test(arguments: [VTSuperResolutionScalerConfiguration.InputType.video, .image])
    func 映像を超解像し音声をそのまま引き継ぐ(inputType: VTSuperResolutionScalerConfiguration.InputType) async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: inputType)

        let scale = try #require(VTSuperResolutionScalerConfiguration.supportedScaleFactors.max())
        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats) = try await video.load(.naturalSize, .formatDescriptions)
        #expect(size == CGSize(width: 160 * scale, height: 90 * scale))
        #expect(formats.first?.mediaSubType == .hevc)
        #expect(try await sampleCount(of: video, in: asset) == 12)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        #expect(audioFormat.mediaSubType == .mpeg4AAC)
    }

    @Test(arguments: [
        ("small.mp4", ColorTags(primaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2", matrix: "ITU_R_709_2")),
        ("small-hlg.mov", ColorTags(primaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG", matrix: "ITU_R_2020")),
    ])
    func 入力の色空間を出力に引き継ぐ(name: String, expected: ColorTags) async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        try await upscaleVideo(input: fixture(name), output: output, inputType: .video)

        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(ColorTags(format) == expected)
    }

    @Test func 上限を超える解像度はエラーで出力を作らない() async throws {
        let output = temporaryURL("mp4")
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("too-large.mp4"), output: output, inputType: .video)
        }
        #expect(error.errorDescription == "入力解像度 1920x1440 は超解像の対象外です（上限 1920x1080）。")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func 既存の出力ファイルは上書きしない() async throws {
        let output = temporaryURL("mp4")
        try Data("existing".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: .video)
        }
        #expect(error.errorDescription == "出力ファイルが既に存在します: \(output.path)")
        #expect(try Data(contentsOf: output) == Data("existing".utf8))
    }

    @Test func 存在しない入力はエラー() async throws {
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: URL(filePath: "/nonexistent.mp4"), output: temporaryURL("mp4"), inputType: .video)
        }
        #expect(error.errorDescription == "入力ファイルが見つかりません: /nonexistent.mp4")
    }

    @Test func 非対応の拡張子はエラー() async throws {
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("small.mp4"), output: temporaryURL("mkv"), inputType: .video)
        }
        #expect(error.errorDescription == "出力の拡張子 .mkv には対応していません（.mov / .mp4 / .m4v のいずれか）。")
    }
}

/// 動画の色空間タグ（色域・伝達関数・YCbCr 行列）。
struct ColorTags: Equatable, Sendable {
    let primaries: String?
    let transferFunction: String?
    let matrix: String?

    init(primaries: String?, transferFunction: String?, matrix: String?) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.matrix = matrix
    }

    init(_ format: CMFormatDescription) {
        func tag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        self.init(
            primaries: tag(kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: tag(kCMFormatDescriptionExtension_TransferFunction),
            matrix: tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        )
    }
}

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

private func temporaryURL(_ pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension(pathExtension)
}

/// トラックの圧縮サンプル数（= フレーム数）を数える。
private func sampleCount(of track: AVAssetTrack, in asset: AVAsset) async throws -> Int {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        count += sample.numSamples
    }
    return count
}
