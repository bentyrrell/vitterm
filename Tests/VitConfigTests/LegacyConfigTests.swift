import XCTest
@testable import VitConfig

final class ConfigTests: XCTestCase {
    func testUnknownThemeIsReported() {
        var c = Config()
        c.parse("theme = light:Solarized Light Light,dark:Solarized Dark")
        c.validate()
        XCTAssertEqual(c.themeDark, "Solarized Dark")
        XCTAssertTrue(c.diagnostics.contains { $0.contains("Solarized Light Light") && $0.contains("did you mean 'Solarized Light'") }, "\(c.diagnostics)")
        var ok = Config()
        ok.parse("theme = Solarized Light")
        ok.validate()
        XCTAssertTrue(ok.diagnostics.isEmpty, "\(ok.diagnostics)")
        XCTAssertEqual(ok.resolvedTheme(systemDark: false).background, 0xFDF6E3)
    }
}

final class ConfigParseTests: XCTestCase {
    func testInlineCommentsAndRioPort() {
        var c = Config()
        c.parse("""
        font-family = Fira Code
        font-size = 16                     # matches Rio
        font-feature = liga, calt          # Fira Code ligatures
        cursor-style = block      # block | bar | underline
        cursor-blink-interval = 600
        background = #fdf6e3
        """)
        XCTAssertTrue(c.diagnostics.isEmpty, "\(c.diagnostics)")
        XCTAssertEqual(c.fontSize, 16)
        XCTAssertEqual(c.fontFeatures, ["liga", "calt"])
        XCTAssertEqual(c.cursorBlinkInterval, 600)
        XCTAssertEqual(c.resolvedTheme(systemDark: false).background, 0xFDF6E3)
    }
}

final class TrailColorTests: XCTestCase {
    func testTrailColorFollowsTheme() {
        var c = Config()
        c.parse("cursor-trail = true")
        let light = Themes.named("Solarized Light")!
        XCTAssertEqual(c.resolvedTrailColor(light), light.palette[5], "defaults to the theme's magenta")
        var themed = light
        themed.apply(key: "cursor-trail-color", value: "#123456")
        XCTAssertEqual(c.resolvedTrailColor(themed), 0x123456, "a theme can define its own trail color")
        c.parse("cursor-trail-color = bright-blue")
        XCTAssertEqual(c.resolvedTrailColor(light), light.palette[12])
        c.parse("cursor-trail-color = cursor")
        XCTAssertEqual(c.resolvedTrailColor(light), light.cursor)
        c.parse("trail-cursor-decay = [100, 400]\ntrail-cursor-opacity = 0.6\ntrail-cursor-start-threshold = 2")
        XCTAssertTrue(c.diagnostics.isEmpty, "\(c.diagnostics)")
        XCTAssertEqual(c.cursorTrailDecaySlow, 400)
    }
}
