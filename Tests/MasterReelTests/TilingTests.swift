import Testing
@testable import MasterReel

struct TilingTests {
    @Test func 横1280を幅480のタイル3枚で重ねて覆う() {
        #expect(tileSpans(total: 1280, tileLength: 480, minimumOverlap: 32) == [
            TileSpan(start: 0, keep: 0..<440),
            TileSpan(start: 400, keep: 440..<840),
            TileSpan(start: 800, keep: 840..<1280),
        ])
    }

    @Test func 縦720を高さ270のタイル3枚で重ねて覆う() {
        #expect(tileSpans(total: 720, tileLength: 270, minimumOverlap: 32) == [
            TileSpan(start: 0, keep: 0..<247),
            TileSpan(start: 225, keep: 247..<472),
            TileSpan(start: 450, keep: 472..<720),
        ])
    }

    @Test func タイルと同じ長さは分けない() {
        #expect(tileSpans(total: 480, tileLength: 480, minimumOverlap: 32) == [TileSpan(start: 0, keep: 0..<480)])
    }

    // 928 は 2 枚をちょうど 32 重ねた長さ、929 は 3 枚が必要になる最小の長さ。
    @Test(arguments: [481, 928, 929, 1024, 1280, 1920])
    func タイルは隙間なく重なり使う範囲が全体をちょうど覆う(total: Int) {
        let spans = tileSpans(total: total, tileLength: 480, minimumOverlap: 32)
        #expect(spans.first?.keep.lowerBound == 0)
        #expect(spans.last?.keep.upperBound == total)
        for (current, next) in zip(spans, spans.dropFirst()) {
            #expect(current.keep.upperBound == next.keep.lowerBound)
            #expect(current.start + 480 - next.start >= 32)
            // 境目からタイルの端までに、重なりの半分以上の余白がある。
            #expect(current.start + 480 - current.keep.upperBound >= 16)
            #expect(next.keep.lowerBound - next.start >= 16)
        }
        for span in spans {
            #expect(span.start >= 0 && span.start + 480 <= total)
        }
    }

    @Test func タイル内での使う範囲() {
        #expect(TileSpan(start: 400, keep: 440..<840).keepInTile == 40..<440)
        #expect(scaled(40..<440, by: 4) == 160..<1760)
    }

    @Test func 画像モードの720pは480x270の3x3に分ける() throws {
        let grid = try #require(tileGrid(width: 1280, height: 720, inputType: .image))
        #expect(grid.tileWidth == 480)
        #expect(grid.tileHeight == 270)
        #expect(grid.columns.map(\.start) == [0, 400, 800])
        #expect(grid.rows.map(\.start) == [0, 225, 450])
    }

    @Test func 縦長の720pも分ける() throws {
        let grid = try #require(tileGrid(width: 720, height: 1280, inputType: .image))
        #expect(grid.columns.count == 2)
        #expect(grid.rows.count == 6)
    }

    @Test func 短い辺がタイルより短ければその方向は分けない() throws {
        let grid = try #require(tileGrid(width: 1920, height: 200, inputType: .image))
        #expect(grid.tileWidth == 480)
        #expect(grid.tileHeight == 200)
        #expect(grid.rows == [TileSpan(start: 0, keep: 0..<200)])
    }

    @Test func 長い辺が1024以下なら分けない() {
        #expect(tileGrid(width: 1024, height: 576, inputType: .image) == nil)
        #expect(tileGrid(width: 960, height: 540, inputType: .image) == nil)
    }

    @Test func 動画モードは分けない() {
        #expect(tileGrid(width: 1280, height: 720, inputType: .video) == nil)
    }
}
