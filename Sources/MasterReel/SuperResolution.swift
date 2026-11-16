import AVFoundation
import VideoToolbox

enum UpscaleError: LocalizedError {
    case inputNotFound(String)
    case unsupportedOutputType(String)
    case outputExists(String)
    case noVideoTrack
    case processorUnsupported
    case unsupportedResolution(width: Int, height: Int, inputType: VTSuperResolutionScalerConfiguration.InputType)
    case interpolationUnsupported
    case unsupportedInterpolationResolution(width: Int, height: Int)
    case frameSetupFailed
    case readFailed(Error?)
    case writeFailed(Error?)
    case cancelled

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
        case let .unsupportedResolution(width, height, inputType):
            "入力解像度 \(width)x\(height) は超解像の対象外です（上限 \(inputType == .image ? "1920x1920" : "1920x1080")）。"
        case .interpolationUnsupported:
            "この Mac では VTFrameRateConversion（フレーム補間）を利用できません。"
        case let .unsupportedInterpolationResolution(width, height):
            "超解像後の解像度 \(width)x\(height) はフレーム補間の対象外です（上限 8192x4320）。"
        case .frameSetupFailed:
            "処理するフレームの準備に失敗しました。"
        case let .readFailed(error):
            "入力動画の読み込みに失敗しました: \(error?.localizedDescription ?? "不明なエラー")"
        case let .writeFailed(error):
            "出力動画の書き出しに失敗しました: \(error?.localizedDescription ?? "不明なエラー")"
        case .cancelled:
            "キャンセルしました。"
        }
    }
}

/// 超解像した1フレームの入力と出力。次のフレームの処理で参照する。
typealias ProcessedFrame = (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame)

/// 圧縮されたまま書き出しへ渡す音声トラックの読み書き口。
private typealias AudioPassthrough = (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)

/// 入力動画を超解像して出力ファイルに書き出す。
/// inputType が .video なら前フレームを参照して時間方向に安定させ、.image なら各フレームを独立に処理する。
/// interpolate が true なら、超解像したフレームの間をフレーム補間で埋めてフレームレートを2倍にする。
/// 先に補間すると超解像するフレームが倍になって遅くなるため、超解像してから補間する。
/// 進捗を progress に書き込み、progress が中止されたら途中で止める。
/// ファイルの読み書き、ML モデルのダウンロード、標準エラーへの進捗出力を伴う。
func upscaleVideo(
    input: URL,
    output: URL,
    inputType: VTSuperResolutionScalerConfiguration.InputType,
    interpolate: Bool,
    progress: Progress = Progress()
) async throws {
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
    let (size, transform, timeScale) = try await videoTrack.load(.naturalSize, .preferredTransform, .naturalTimeScale)
    let duration = try await asset.load(.duration)

    let configuration = try makeConfiguration(width: Int(size.width), height: Int(size.height), inputType: inputType)
    let outputWidth = configuration.frameWidth * configuration.scaleFactor
    let outputHeight = configuration.frameHeight * configuration.scaleFactor
    let interpolation = interpolate ? try makeInterpolationConfiguration(width: outputWidth, height: outputHeight) : nil
    // タイルに分けるときは、プロセッサーをタイルの大きさで設定する。
    let tiling = try makeTiling(width: configuration.frameWidth, height: configuration.frameHeight, inputType: inputType)
    let processorConfiguration = tiling?.configuration ?? configuration
    try await ensureModelAvailable(for: processorConfiguration)
    printStatus("\(configuration.frameWidth)x\(configuration.frameHeight) → \(outputWidth)x\(outputHeight)（\(configuration.scaleFactor)倍）")
    if let grid = tiling?.grid {
        printStatus("\(grid.tileWidth)x\(grid.tileHeight) のタイル \(grid.columns.count * grid.rows.count) 枚に分けて超解像します。")
    }
    if interpolate {
        printStatus("フレーム補間でフレームレートを 2 倍にします。")
    }

    // 映像は超解像の入力形式にデコードして HEVC で書き出す。
    // 色空間は各フレームの付加情報として引き継ぐ（upscaleFrame を参照）。
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: configuration.sourcePixelBufferAttributes)
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(width: outputWidth, height: outputHeight))
    videoInput.transform = transform
    // 既定のタイムスケール（600）では時刻が丸められるため、入力のタイムスケールで書く。
    // 補間フレームは2つのフレームの中間に入るので、タイムスケールを2倍にして中間の時刻も表せるようにする。
    videoInput.mediaTimeScale = timeScale * (interpolate ? 2 : 1)
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

    let processor = try startedProcessor(processorConfiguration)
    defer { processor.endSession() }
    // 1つのセッションでは1種類の処理しかできないため、補間には別のプロセッサーを使う。
    let interpolator = try interpolation.map { try startedProcessor($0) }
    defer { interpolator?.endSession() }

    do {
        try await transfer(
            video: (videoOutput, adaptor),
            audio: audio,
            processor: processor,
            tiling: tiling,
            interpolator: interpolator,
            inputType: inputType,
            duration: duration.seconds,
            progress: progress
        )
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
func makeConfiguration(
    width: Int,
    height: Int,
    inputType: VTSuperResolutionScalerConfiguration.InputType
) throws -> VTSuperResolutionScalerConfiguration {
    guard
        VTSuperResolutionScalerConfiguration.isSupported,
        let scaleFactor = VTSuperResolutionScalerConfiguration.supportedScaleFactors.max()
    else { throw UpscaleError.processorUnsupported }
    guard let configuration = VTSuperResolutionScalerConfiguration(
        frameWidth: width,
        frameHeight: height,
        scaleFactor: scaleFactor,
        inputType: inputType,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTSuperResolutionScalerConfiguration.defaultRevision
    ) else { throw UpscaleError.unsupportedResolution(width: width, height: height, inputType: inputType) }
    return configuration
}

/// 設定した処理のセッションを始めたプロセッサーを返す（ML モデルの読み込みを伴う）。
private func startedProcessor(_ configuration: some VTFrameProcessorConfiguration) throws -> VTFrameProcessor {
    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    return processor
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
/// tiling があれば、各フレームをタイルに分けて超解像する。
/// interpolator があれば、超解像したフレームと前のフレームの間に補間フレームを挟む。
/// progress が中止されたら、次のフレームを処理する前に UpscaleError.cancelled を投げる。
private func transfer(
    video: (output: AVAssetReaderTrackOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor),
    audio: [AudioPassthrough],
    processor: VTFrameProcessor,
    tiling: Tiling?,
    interpolator: VTFrameProcessor?,
    inputType: VTSuperResolutionScalerConfiguration.InputType,
    duration: Double,
    progress: Progress
) async throws {
    let videoInput = video.adaptor.assetWriterInput
    var videoFinished = false
    // 1フレームの超解像で補間フレームと合わせて2フレームできることがあるので、書き出しを待つ列に積んでから1つずつ書く。
    var pendingVideo: [VTFrameProcessorFrame] = []
    var pendingAudio = audio
    // 動画モードは前フレームを参照して順に処理し、画像モードは各フレームを独立に処理する。
    let submissionMode: VTSuperResolutionScalerParameters.SubmissionMode = inputType == .video ? .sequential : .random
    var previous: ProcessedFrame?
    var frames = 0
    let start = ContinuousClock.now

    while !videoFinished || !pendingAudio.isEmpty {
        if progress.isCancelled { throw UpscaleError.cancelled }
        var progressed = false

        if !videoFinished, videoInput.isReadyForMoreMediaData {
            progressed = true
            if !pendingVideo.isEmpty {
                let frame = pendingVideo.removeFirst()
                guard video.adaptor.append(frame.buffer, withPresentationTime: frame.presentationTimeStamp) else {
                    throw UpscaleError.writeFailed(nil)
                }
            } else if let sample = video.output.copyNextSampleBuffer() {
                if let sourceBuffer = sample.imageBuffer {
                    let time = sample.presentationTimeStamp
                    let pool = video.adaptor.pixelBufferPool
                    let frame = if let tiling {
                        try await upscaleFrameInTiles(sourceBuffer, at: time, tiling: tiling, processor: processor, pool: pool)
                    } else {
                        try await upscaleFrame(sourceBuffer, at: time, previous: previous, submissionMode: submissionMode, processor: processor, pool: pool)
                    }
                    if let interpolator, let previous {
                        let middle = try await interpolateFrame(between: previous.output, and: frame.output, processor: interpolator, pool: pool)
                        pendingVideo.append(middle)
                    }
                    pendingVideo.append(frame.output)
                    previous = frame
                    frames += 1
                    let elapsed = (ContinuousClock.now - start) / .seconds(1)
                    printStatus("\r" + progressLine(position: time.seconds, duration: duration, frames: frames, elapsed: elapsed), terminator: "")
                    updateMenuBarProgress(progress, fraction: progressFraction(position: time.seconds, duration: duration), elapsed: elapsed)
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

/// 1フレームを超解像する。.sequential では前フレームの入力と出力を参照し、フレーム間のちらつきを抑える。
/// .random では前フレームを参照せず、フレームを独立に処理する。
func upscaleFrame(
    _ sourceBuffer: CVPixelBuffer,
    at time: CMTime,
    previous: ProcessedFrame?,
    submissionMode: VTSuperResolutionScalerParameters.SubmissionMode,
    processor: VTFrameProcessor,
    pool: CVPixelBufferPool?
) async throws -> ProcessedFrame {
    guard
        let source = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: time),
        let output = makeDestinationFrame(pool: pool, at: time),
        let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: source,
            previousFrame: submissionMode == .sequential ? previous?.source : nil,
            previousOutputFrame: submissionMode == .sequential ? previous?.output : nil,
            opticalFlow: nil,
            submissionMode: submissionMode,
            destinationFrame: output
        )
    else { throw UpscaleError.frameSetupFailed }

    // 同名でフレーム列を返す（処理完了を待たない）版と取り違えないよう、戻り値の型で処理完了を待つ版を選ぶ。
    let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
    // 色空間などの付加情報を入力フレームから引き継ぎ、エンコーダーが出力に正しい色情報を付けられるようにする。
    CVBufferPropagateAttachments(sourceBuffer, output.buffer)
    return (source, output)
}

/// 処理結果を受け取るフレームを、プールから確保したバッファーで作る。確保できなければ nil。
func makeDestinationFrame(pool: CVPixelBufferPool?, at time: CMTime) -> VTFrameProcessorFrame? {
    var buffer: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    return VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time)
}
