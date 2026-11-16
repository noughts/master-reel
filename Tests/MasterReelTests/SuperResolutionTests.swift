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

        try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: inputType, interpolate: false)

        let scale = try #require(VTSuperResolutionScalerConfiguration.supportedScaleFactors.max())
        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats) = try await video.load(.naturalSize, .formatDescriptions)
        #expect(size == CGSize(width: 160 * scale, height: 90 * scale))
        #expect(formats.first?.mediaSubType == .hevc)
        #expect(try await presentationTimes(of: output).count == 12)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        #expect(audioFormat.mediaSubType == .mpeg4AAC)
    }

    @Test func タイルに分けて超解像しても元の絵を保つ() async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        // 1280x720 の画像モードは、480x270 のタイルに分けて超解像する。
        try await upscaleVideo(input: fixture("small-720p.mp4"), output: output, inputType: .image, interpolate: false)

        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 5120, height: 2880))
        // 入力と出力を同じ大きさに縮小して比べると、ほぼ一致する。タイルの位置を誤ると大きくずれる。
        let source = try await decodedFrames(of: fixture("small-720p.mp4"), width: 320, height: 180)
        let upscaled = try await decodedFrames(of: output, width: 320, height: 180)
        #expect(upscaled.count == 3)
        #expect(meanAbsoluteDifference(source, upscaled) < 3)
    }

    @Test func 補間フレームを前後のフレームの中間時刻に挟む() async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: .image, interpolate: true)

        let sourceTimes = try await presentationTimes(of: fixture("small.mp4"))
        let middleTimes = zip(sourceTimes, sourceTimes.dropFirst()).map { midpointTime($0, $1) }
        let expected = (sourceTimes + middleTimes).sorted { $0 < $1 }
        #expect(expected.count == 23)
        let actual = try await presentationTimes(of: output)
        #expect(actual == expected)
    }

    @Test(arguments: [
        ("small.mp4", ColorTags(primaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2", matrix: "ITU_R_709_2")),
        ("small-hlg.mov", ColorTags(primaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG", matrix: "ITU_R_2020")),
    ])
    func 入力の色空間を出力に引き継ぐ(name: String, expected: ColorTags) async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        try await upscaleVideo(input: fixture(name), output: output, inputType: .video, interpolate: false)

        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(ColorTags(format) == expected)
    }

    @Test func 超解像しながら進捗を更新する() async throws {
        let output = temporaryURL("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let progress = Progress(totalUnitCount: 1000)

        try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: .image, interpolate: false, progress: progress)

        // 最後のフレームの時刻は動画の長さより1フレーム分手前なので、100% の少し手前で終わる。
        #expect(progress.fractionCompleted > 0.9)
    }

    @Test func 進捗が中止されたら途中で止めて出力を残さない() async throws {
        let output = temporaryURL("mov")
        let progress = Progress(totalUnitCount: 1000)
        progress.cancel()

        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: .image, interpolate: false, progress: progress)
        }
        #expect(error.errorDescription == "キャンセルしました。")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func 上限を超える解像度はエラーで出力を作らない() async throws {
        let output = temporaryURL("mp4")
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("too-large.mp4"), output: output, inputType: .video, interpolate: false)
        }
        #expect(error.errorDescription == "入力解像度 1920x1440 は超解像の対象外です（上限 1920x1080）。")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func 超解像後に補間の上限を超える解像度はエラーで出力を作らない() async throws {
        let output = temporaryURL("mp4")
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("too-large.mp4"), output: output, inputType: .image, interpolate: true)
        }
        #expect(error.errorDescription == "超解像後の解像度 7680x5760 はフレーム補間の対象外です（上限 8192x4320）。")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func 既存の出力ファイルは上書きしない() async throws {
        let output = temporaryURL("mp4")
        try Data("existing".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("small.mp4"), output: output, inputType: .video, interpolate: false)
        }
        #expect(error.errorDescription == "出力ファイルが既に存在します: \(output.path)")
        #expect(try Data(contentsOf: output) == Data("existing".utf8))
    }

    @Test func 存在しない入力はエラー() async throws {
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: URL(filePath: "/nonexistent.mp4"), output: temporaryURL("mp4"), inputType: .video, interpolate: false)
        }
        #expect(error.errorDescription == "入力ファイルが見つかりません: /nonexistent.mp4")
    }

    @Test func 非対応の拡張子はエラー() async throws {
        let error = try await #require(throws: UpscaleError.self) {
            try await upscaleVideo(input: fixture("small.mp4"), output: temporaryURL("mkv"), inputType: .video, interpolate: false)
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

/// 動画を BGRA にデコードし、映像フレームのサンプルを表示順に返す。outputSettings で縮小もできる。
/// 圧縮されたまま読むと編集リストによるずれや空のサンプルが混ざるため、デコード後のサンプルを使う。
private func decodedSamples(of url: URL, outputSettings: [String: Any] = [:]) async throws -> [CMSampleBuffer] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: outputSettings.merging([kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) { $1 }
    )
    reader.add(output)
    reader.startReading()
    var samples: [CMSampleBuffer] = []
    while let sample = output.copyNextSampleBuffer() {
        if sample.imageBuffer != nil {
            samples.append(sample)
        }
    }
    return samples
}

/// 動画の映像フレームの表示時刻を、表示順に返す。
private func presentationTimes(of url: URL) async throws -> [CMTime] {
    try await decodedSamples(of: url).map(\.presentationTimeStamp)
}

/// 動画の各フレームを width x height に縮小した BGRA の画素として、表示順に返す。
private func decodedFrames(of url: URL, width: Int, height: Int) async throws -> [[UInt8]] {
    let samples = try await decodedSamples(of: url, outputSettings: [
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    return try samples.map { sample in
        let buffer = try #require(sample.imageBuffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return (0..<height).flatMap { row in
            Array(UnsafeRawBufferPointer(start: base + row * rowBytes, count: width * 4))
        }
    }
}

/// 同じ大きさのフレーム列どうしの、画素値（0〜255）の差の絶対値の平均。
private func meanAbsoluteDifference(_ a: [[UInt8]], _ b: [[UInt8]]) -> Double {
    let pairs = zip(a.joined(), b.joined())
    let total = pairs.reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    return Double(total) / Double(a.joined().count)
}
