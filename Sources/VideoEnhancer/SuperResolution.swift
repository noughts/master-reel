import AVFoundation
import VideoToolbox

enum UpscaleError: LocalizedError {
    case inputNotFound(String)
    case unsupportedOutputType(String)
    case outputExists(String)
    case noVideoTrack
    case processorUnsupported
    case unsupportedResolution(width: Int, height: Int)
    case frameSetupFailed
    case readFailed(Error?)
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case let .inputNotFound(path):
            "入力ファイルが見つかりません: \(path)"
        case let .unsupportedOutputType(pathExtension):
            "出力の拡張子 .\(pathExtension) には対応していません（.mov / .mp4 / .m4v のいずれか）。"
        case let .outputExists(path):
            "出力ファイルが既に存在します: \(path)"
        case .noVideoTrack:
            "入力ファイルに映像トラックがありません。"
        case .processorUnsupported:
            "この Mac では VTSuperResolutionScaler を利用できません。"
        case let .unsupportedResolution(width, height):
            "入力解像度 \(width)x\(height) は超解像の対象外です（上限 1920x1080）。"
        case .frameSetupFailed:
            "超解像するフレームの準備に失敗しました。"
        case let .readFailed(error):
            "入力動画の読み込みに失敗しました: \(error?.localizedDescription ?? "不明なエラー")"
        case let .writeFailed(error):
            "出力動画の書き出しに失敗しました: \(error?.localizedDescription ?? "不明なエラー")"
        }
    }
}

/// 超解像した1フレームの入力と出力。次のフレームの処理で参照する。
private typealias ProcessedFrame = (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame)

/// 圧縮されたまま書き出しへ渡す音声トラックの読み書き口。
private typealias AudioPassthrough = (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)

/// 入力動画を超解像して出力ファイルに書き出す。
/// ファイルの読み書き、ML モデルのダウンロード、標準エラーへの進捗出力を伴う。
func upscaleVideo(input: URL, output: URL) async throws {
    guard let fileType = outputFileType(forPathExtension: output.pathExtension) else {
        throw UpscaleError.unsupportedOutputType(output.pathExtension)
    }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw UpscaleError.outputExists(output.path)
    }
    guard FileManager.default.fileExists(atPath: input.path) else {
        throw UpscaleError.inputNotFound(input.path)
    }

    let asset = AVURLAsset(url: input)
    let videoTracks: [AVAssetTrack]
    let audioTracks: [AVAssetTrack]
    do {
        videoTracks = try await asset.loadTracks(withMediaType: .video)
        audioTracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
        throw UpscaleError.readFailed(error)
    }
    guard let videoTrack = videoTracks.first else { throw UpscaleError.noVideoTrack }
    let (size, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
    let duration = try await asset.load(.duration)

    let configuration = try makeConfiguration(width: Int(size.width), height: Int(size.height))
    try await ensureModelAvailable(for: configuration)
    let outputWidth = configuration.frameWidth * configuration.scaleFactor
    let outputHeight = configuration.frameHeight * configuration.scaleFactor
    printStatus("\(configuration.frameWidth)x\(configuration.frameHeight) → \(outputWidth)x\(outputHeight)（\(configuration.scaleFactor)倍）")

    // 映像は超解像の入力形式にデコードして HEVC で書き出す。
    // 色空間は各フレームの付加情報として引き継ぐ（upscaleFrame を参照）。
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: configuration.sourcePixelBufferAttributes)
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(width: outputWidth, height: outputHeight))
    videoInput.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: configuration.destinationPixelBufferAttributes
    )
    writer.add(videoInput)

    // 音声は圧縮されたまま取り出し、再エンコードせずに書き出す。
    var audio: [AudioPassthrough] = []
    for track in audioTracks {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
        reader.add(output)
        writer.add(input)
        audio.append((output, input))
    }

    guard reader.startReading() else { throw UpscaleError.readFailed(reader.error) }
    guard writer.startWriting() else { throw UpscaleError.writeFailed(writer.error) }
    writer.startSession(atSourceTime: .zero)

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    defer { processor.endSession() }

    do {
        try await transfer(video: (videoOutput, adaptor), audio: audio, processor: processor, duration: duration.seconds)
    } catch {
        // 書き出し側が原因なら、その理由を優先して伝える。
        let cause = writer.status == .failed ? UpscaleError.writeFailed(writer.error) : error
        reader.cancelReading()
        writer.cancelWriting()
        throw cause
    }

    if reader.status == .failed { throw UpscaleError.readFailed(reader.error) }
    await writer.finishWriting()
    if writer.status != .completed { throw UpscaleError.writeFailed(writer.error) }
}

/// 入力解像度に対する超解像の設定を作る。対応できるうちで最大の倍率を使う。
private func makeConfiguration(width: Int, height: Int) throws -> VTSuperResolutionScalerConfiguration {
    guard
        VTSuperResolutionScalerConfiguration.isSupported,
        let scaleFactor = VTSuperResolutionScalerConfiguration.supportedScaleFactors.max()
    else { throw UpscaleError.processorUnsupported }
    guard let configuration = VTSuperResolutionScalerConfiguration(
        frameWidth: width,
        frameHeight: height,
        scaleFactor: scaleFactor,
        inputType: .video,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTSuperResolutionScalerConfiguration.defaultRevision
    ) else { throw UpscaleError.unsupportedResolution(width: width, height: height) }
    return configuration
}

/// 超解像の ML モデルが未取得ならダウンロードし、進捗を表示する（ネットワーク通信を伴う）。
private func ensureModelAvailable(for configuration: VTSuperResolutionScalerConfiguration) async throws {
    guard configuration.configurationModelStatus != .ready else { return }
    printStatus("超解像モデルをダウンロードします（初回のみ）。")
    let monitor = Task {
        while !Task.isCancelled {
            let percent = Int(configuration.configurationModelPercentageAvailable * 100)
            printStatus("\rモデルをダウンロード中 \(percent)%", terminator: "")
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    defer { monitor.cancel() }
    try await configuration.downloadConfigurationModel()
    printStatus("\rモデルのダウンロードが完了しました。")
}

/// 映像を1フレームずつ超解像しながら、音声と交互に書き出す。
/// AVAssetWriter はトラック間の時刻を揃えて書くため、片方だけを先に流し込むと止まる。
/// そのため受け入れ可能になった入力から順に供給する。
private func transfer(
    video: (output: AVAssetReaderTrackOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor),
    audio: [AudioPassthrough],
    processor: VTFrameProcessor,
    duration: Double
) async throws {
    let videoInput = video.adaptor.assetWriterInput
    var videoFinished = false
    var pendingAudio = audio
    var previous: ProcessedFrame?
    var frames = 0
    let start = ContinuousClock.now

    while !videoFinished || !pendingAudio.isEmpty {
        var progressed = false

        if !videoFinished, videoInput.isReadyForMoreMediaData {
            progressed = true
            if let sample = video.output.copyNextSampleBuffer() {
                if let sourceBuffer = sample.imageBuffer {
                    let time = sample.presentationTimeStamp
                    let frame = try await upscaleFrame(sourceBuffer, at: time, previous: previous, processor: processor, pool: video.adaptor.pixelBufferPool)
                    guard video.adaptor.append(frame.output.buffer, withPresentationTime: time) else {
                        throw UpscaleError.writeFailed(nil)
                    }
                    previous = frame
                    frames += 1
                    let elapsed = (ContinuousClock.now - start) / .seconds(1)
                    printStatus("\r" + progressLine(position: time.seconds, duration: duration, frames: frames, elapsed: elapsed), terminator: "")
                }
            } else {
                videoInput.markAsFinished()
                videoFinished = true
                printStatus("")
            }
        }

        var unfinishedAudio: [AudioPassthrough] = []
        for track in pendingAudio {
            var finished = false
            while !finished, track.input.isReadyForMoreMediaData {
                progressed = true
                if let sample = track.output.copyNextSampleBuffer() {
                    track.input.append(sample)
                } else {
                    track.input.markAsFinished()
                    finished = true
                }
            }
            if !finished { unfinishedAudio.append(track) }
        }
        pendingAudio = unfinishedAudio

        if !progressed {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// 1フレームを超解像する。前フレームの入力と出力を渡すと、フレーム間のちらつきが抑えられる。
private func upscaleFrame(
    _ sourceBuffer: CVPixelBuffer,
    at time: CMTime,
    previous: ProcessedFrame?,
    processor: VTFrameProcessor,
    pool: CVPixelBufferPool?
) async throws -> ProcessedFrame {
    var outputBuffer: CVPixelBuffer?
    guard
        let pool,
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
        let outputBuffer,
        let source = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: time),
        let output = VTFrameProcessorFrame(buffer: outputBuffer, presentationTimeStamp: time),
        let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: source,
            previousFrame: previous?.source,
            previousOutputFrame: previous?.output,
            opticalFlow: nil,
            submissionMode: .sequential,
            destinationFrame: output
        )
    else { throw UpscaleError.frameSetupFailed }

    // 同名でフレーム列を返す（処理完了を待たない）版と取り違えないよう、戻り値の型で処理完了を待つ版を選ぶ。
    let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
    // 色空間などの付加情報を入力フレームから引き継ぎ、エンコーダーが出力に正しい色情報を付けられるようにする。
    CVBufferPropagateAttachments(sourceBuffer, outputBuffer)
    return (source, output)
}
