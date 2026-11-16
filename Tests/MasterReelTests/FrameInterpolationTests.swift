import CoreMedia
import Testing
@testable import MasterReel

struct FrameInterpolationTests {
    @Test func 中間時刻を返す() {
        #expect(midpointTime(CMTime(value: 0, timescale: 12288), CMTime(value: 512, timescale: 12288)) == CMTime(value: 256, timescale: 12288))
    }

    @Test func 元のタイムスケールで割り切れない中間時刻も丸めない() {
        // 24fps・タイムスケール 600 では 1 フレームが 25 なので、中間は 12.5/600 になる。
        let middle = midpointTime(CMTime(value: 25, timescale: 600), CMTime(value: 50, timescale: 600))
        #expect(middle == CMTime(value: 75, timescale: 1200))
        #expect(middle.seconds == 0.0625)
    }

    @Test func タイムスケールが異なる時刻の中間() {
        #expect(midpointTime(CMTime(value: 1, timescale: 2), CMTime(value: 1, timescale: 3)).seconds == 5.0 / 12)
    }
}
