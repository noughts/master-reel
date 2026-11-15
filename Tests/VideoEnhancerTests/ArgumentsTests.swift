import Testing
@testable import VideoEnhancer

struct ArgumentsTests {
    @Test func 入力と出力を受け取る() throws {
        #expect(try parseArguments(["in.mp4", "out.mov"]) == .upscale(input: "in.mp4", output: "out.mov"))
    }

    @Test(arguments: [["-h"], ["--help"], ["in.mp4", "--help"]])
    func ヘルプ指定はほかの引数より優先する(arguments: [String]) throws {
        #expect(try parseArguments(arguments) == .help)
    }

    @Test(arguments: [[], ["in.mp4"], ["a.mp4", "b.mp4", "c.mp4"]])
    func パスが2つでなければエラー(arguments: [String]) {
        #expect(throws: UsageError(message: "入力動画と出力動画のパスを1つずつ指定してください。")) {
            try parseArguments(arguments)
        }
    }

    @Test func 不明なオプションはエラー() {
        #expect(throws: UsageError(message: "不明なオプションです: --scale")) {
            try parseArguments(["in.mp4", "out.mp4", "--scale"])
        }
    }
}
