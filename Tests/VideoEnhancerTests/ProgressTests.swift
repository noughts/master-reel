import Testing
@testable import VideoEnhancer

struct ProgressTests {
    @Test func 途中では割合と速度と残り時間を出す() {
        #expect(
            progressLine(position: 2.5, duration: 10, frames: 60, elapsed: 30)
                == "超解像中  25.0%  60 フレーム  2.0 fps  残り約 1:30"
        )
    }

    @Test func 終端では残り時間を出さない() {
        #expect(
            progressLine(position: 10, duration: 10, frames: 240, elapsed: 120)
                == "超解像中 100.0%  240 フレーム  2.0 fps"
        )
    }

    @Test func 長さや経過時間が0でも割り算しない() {
        #expect(progressLine(position: 0, duration: 0, frames: 0, elapsed: 0) == "超解像中   0.0%  0 フレーム  - fps")
    }

    @Test func 範囲外の位置は0から100パーセントに収める() {
        #expect(progressLine(position: 12, duration: 10, frames: 1, elapsed: 1).hasPrefix("超解像中 100.0%"))
        #expect(progressLine(position: -1, duration: 10, frames: 1, elapsed: 1).hasPrefix("超解像中   0.0%"))
    }

    @Test func 時間の表記() {
        #expect(formatDuration(0) == "0:00")
        #expect(formatDuration(59.6) == "1:00")
        #expect(formatDuration(3599) == "59:59")
        #expect(formatDuration(3661) == "1:01:01")
    }
}
