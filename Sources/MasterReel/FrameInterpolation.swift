import CoreMedia
import VideoToolbox

/// 超解像後の解像度に対するフレーム補間の設定を作る。
/// フレーム補間は超解像の出力（16 bit 浮動小数の RGBA）をそのまま入力にできる。
func makeInterpolationConfiguration(width: Int, height: Int) throws -> VTFrameRateConversionConfiguration {
    guard VTFrameRateConversionConfiguration.isSupported else { throw UpscaleError.interpolationUnsupported }
    guard let configuration = VTFrameRateConversionConfiguration(
        frameWidth: width,
        frameHeight: height,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision
    ) else { throw UpscaleError.unsupportedInterpolationResolution(width: width, height: height) }
    return configuration
}

/// 2つの時刻のちょうど中間の時刻。
/// 元のタイムスケールでは割り切れないことがあるため、タイムスケールを2倍にして端数を出さない。
func midpointTime(_ first: CMTime, _ second: CMTime) -> CMTime {
    let sum = CMTimeAdd(first, second)
    return CMTime(value: sum.value, timescale: sum.timescale * 2)
}

/// 連続する2フレームのちょうど中間のフレームを、フレーム補間で作る。
func interpolateFrame(
    between first: VTFrameProcessorFrame,
    and second: VTFrameProcessorFrame,
    processor: VTFrameProcessor,
    pool: CVPixelBufferPool?
) async throws -> VTFrameProcessorFrame {
    guard
        let destination = makeDestinationFrame(pool: pool, at: midpointTime(first.presentationTimeStamp, second.presentationTimeStamp)),
        let parameters = VTFrameRateConversionParameters(
            sourceFrame: first,
            nextFrame: second,
            opticalFlow: nil,
            interpolationPhase: [0.5],
            submissionMode: .sequential,
            destinationFrames: [destination]
        )
    else { throw UpscaleError.frameSetupFailed }

    let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
    // 補間フレームには付加情報が付かないので、前のフレームから色空間などを引き継ぐ。
    CVBufferPropagateAttachments(first.buffer, destination.buffer)
    return destination
}
