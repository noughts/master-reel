import VideoToolbox

/// タイルの1方向の位置（入力フレームの画素単位）。
/// start からタイルの長さだけ超解像し、そのうち keep の範囲だけを出力に使う。
struct TileSpan: Equatable {
    let start: Int
    let keep: Range<Int>

    /// keep を、タイルの左上を原点とした範囲で表したもの。
    var keepInTile: Range<Int> { (keep.lowerBound - start)..<(keep.upperBound - start) }
}

/// 1フレームを覆うタイルの並び。どのタイルも tileWidth x tileHeight で、columns と rows の組み合わせの位置に置く。
struct TileGrid: Equatable {
    let tileWidth: Int
    let tileHeight: Int
    let columns: [TileSpan]
    let rows: [TileSpan]
}

/// 画像モードで超解像するときの、タイルの並びを決める。分ける必要がなければ nil。
/// 画像モードは長い辺が 1024 を超えると急に遅くなるため、速く処理される寸法の 480x270 に分ける（M5 で実測。README を参照）。
/// 動画モードはこの遅くなり方をしないので分けない。
func tileGrid(width: Int, height: Int, inputType: VTSuperResolutionScalerConfiguration.InputType) -> TileGrid? {
    guard inputType == .image, max(width, height) > 1024 else { return nil }
    let tileWidth = min(width, 480)
    let tileHeight = min(height, 270)
    return TileGrid(
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        columns: tileSpans(total: width, tileLength: tileWidth, minimumOverlap: 32),
        rows: tileSpans(total: height, tileLength: tileHeight, minimumOverlap: 32)
    )
}

/// 長さ total を、長さ tileLength（total 以下）のタイルを等間隔に並べて覆う。
/// 隣り合うタイルは minimumOverlap 以上重ね、重なりの中央で使うタイルを切り替える。
/// タイルの端は周りの画素がない分だけ結果が変わり、そのまま並べると継ぎ目が見えるため。
func tileSpans(total: Int, tileLength: Int, minimumOverlap: Int) -> [TileSpan] {
    guard total > tileLength else { return [TileSpan(start: 0, keep: 0..<total)] }
    // count 枚を重ねて並べた長さ count * tileLength - (count - 1) * minimumOverlap が total 以上になる最小の枚数。
    let step = tileLength - minimumOverlap
    let count = (total - minimumOverlap + step - 1) / step
    let starts = (0..<count).map { $0 * (total - tileLength) / (count - 1) }
    // 隣のタイルとの重なりの中央を境目にする。
    let boundaries = [0] + zip(starts, starts.dropFirst()).map { ($0 + tileLength + $1) / 2 } + [total]
    return starts.indices.map { index in
        TileSpan(start: starts[index], keep: boundaries[index]..<boundaries[index + 1])
    }
}

/// 範囲の両端を factor 倍する。
func scaled(_ range: Range<Int>, by factor: Int) -> Range<Int> {
    (range.lowerBound * factor)..<(range.upperBound * factor)
}

/// タイルに分けて超解像するための並び・タイルの大きさの設定と、使い回す作業用のバッファー。
struct Tiling {
    let grid: TileGrid
    let configuration: VTSuperResolutionScalerConfiguration
    /// タイル1枚分の入力を切り出すバッファー。
    let source: CVPixelBuffer
    /// タイル1枚分の超解像の結果を受け取るバッファーのプール。
    let outputPool: CVPixelBufferPool
}

/// タイルに分けて超解像する必要があれば、その並びとタイルの大きさの設定・作業用のバッファーを用意する。不要なら nil。
func makeTiling(width: Int, height: Int, inputType: VTSuperResolutionScalerConfiguration.InputType) throws -> Tiling? {
    guard let grid = tileGrid(width: width, height: height, inputType: inputType) else { return nil }
    let configuration = try makeConfiguration(width: grid.tileWidth, height: grid.tileHeight, inputType: inputType)
    var sourcePool: CVPixelBufferPool?
    var outputPool: CVPixelBufferPool?
    var source: CVPixelBuffer?
    guard
        CVPixelBufferPoolCreate(nil, nil, configuration.sourcePixelBufferAttributes as CFDictionary, &sourcePool) == kCVReturnSuccess,
        let sourcePool,
        CVPixelBufferPoolCreatePixelBuffer(nil, sourcePool, &source) == kCVReturnSuccess,
        let source,
        // copyPixels は 64 bit RGBA half を前提に複写する。
        CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_64RGBAHalf,
        CVPixelBufferPoolCreate(nil, nil, configuration.destinationPixelBufferAttributes as CFDictionary, &outputPool) == kCVReturnSuccess,
        let outputPool
    else { throw UpscaleError.frameSetupFailed }
    return Tiling(grid: grid, configuration: configuration, source: source, outputPool: outputPool)
}

/// 1フレームをタイルに分けて超解像し、出力フレームにつなぎ合わせる。各タイルは前のフレームを参照せず独立に処理する。
func upscaleFrameInTiles(
    _ sourceBuffer: CVPixelBuffer,
    at time: CMTime,
    tiling: Tiling,
    processor: VTFrameProcessor,
    pool: CVPixelBufferPool?
) async throws -> ProcessedFrame {
    guard
        let source = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: time),
        let output = makeDestinationFrame(pool: pool, at: time)
    else { throw UpscaleError.frameSetupFailed }
    let grid = tiling.grid
    let scale = tiling.configuration.scaleFactor
    for row in grid.rows {
        for column in grid.columns {
            copyPixels(
                of: sourceBuffer,
                columns: column.start..<(column.start + grid.tileWidth),
                rows: row.start..<(row.start + grid.tileHeight),
                to: tiling.source, x: 0, y: 0
            )
            let tile = try await upscaleFrame(tiling.source, at: time, previous: nil, submissionMode: .random, processor: processor, pool: tiling.outputPool)
            copyPixels(
                of: tile.output.buffer,
                columns: scaled(column.keepInTile, by: scale),
                rows: scaled(row.keepInTile, by: scale),
                to: output.buffer, x: column.keep.lowerBound * scale, y: row.keep.lowerBound * scale
            )
        }
    }
    CVBufferPropagateAttachments(sourceBuffer, output.buffer)
    return (source, output)
}

/// source の columns × rows の画素を、destination の (x, y) を左上として CPU で複写する。
/// 超解像の入出力形式である 64 bit RGBA half（1 画素 8 バイト）のバッファー専用。
private func copyPixels(of source: CVPixelBuffer, columns: Range<Int>, rows: Range<Int>, to destination: CVPixelBuffer, x: Int, y: Int) {
    let bytesPerPixel = 8
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(destination, [])
    defer {
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        CVPixelBufferUnlockBaseAddress(destination, [])
    }
    guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else { return }
    let fromRowBytes = CVPixelBufferGetBytesPerRow(source)
    let toRowBytes = CVPixelBufferGetBytesPerRow(destination)
    for (offset, row) in rows.enumerated() {
        memcpy(
            to + (y + offset) * toRowBytes + x * bytesPerPixel,
            from + row * fromRowBytes + columns.lowerBound * bytesPerPixel,
            columns.count * bytesPerPixel
        )
    }
}
