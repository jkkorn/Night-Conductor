import XCTest

@testable import NightConductor

/// Security audit H1/H2: everything about a stalled session comes from files
/// other programs wrote, and it ends up as arguments and the working directory
/// of an unattended agent that auto-accepts edits.
final class ResumeSafetyTests: XCTestCase {
    private let home = "/Users/alex"

    // H1: an id beginning with "-" would be parsed by `claude` as a flag.
    func testSessionIDMustBeAUUID() {
        XCTAssertTrue(ResumeSafety.isValidSessionID("01a1a6ba-5a46-77f1-b25a-8a547f7594d1"))
        XCTAssertFalse(ResumeSafety.isValidSessionID("--dangerously-skip-permissions"))
        XCTAssertFalse(ResumeSafety.isValidSessionID("--settings=/tmp/evil.json"))
        XCTAssertFalse(ResumeSafety.isValidSessionID(""))
        XCTAssertFalse(ResumeSafety.isValidSessionID("01a1a6ba-5a46-77f1-b25a-8a547f7594d1 --x"))
    }

    // H2: a crafted row must not aim an acceptEdits agent at $HOME or dotfiles.
    func testWorkspaceMustBeAProjectFolderUnderHome() {
        XCTAssertTrue(ResumeSafety.isSafeWorkspace("/Users/alex/conductor/workspaces/app/oslo", home: home))
        XCTAssertTrue(ResumeSafety.isSafeWorkspace("/Users/alex/code/site", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex/", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/etc", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alexander/code", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex/.ssh", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex/code/.git/hooks", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex/Library/LaunchAgents", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("/Users/alex/code/../.ssh", home: home))
        XCTAssertFalse(ResumeSafety.isSafeWorkspace("relative/path", home: home))
    }

    func testSymlinkIntoDotDirIsRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID())")
        let secret = base.appendingPathComponent(".secret")
        let link = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let root = base.resolvingSymlinksInPath().deletingLastPathComponent().path
        XCTAssertFalse(ResumeSafety.isSafeWorkspace(link.path, home: root))
    }

    // Terminal transcripts: the folder Claude Code filed the transcript under
    // must be the encoding of the cwd the file claims.
    func testTranscriptCwdMustMatchItsProjectFolder() {
        XCTAssertTrue(ResumeSafety.cwdMatchesProjectDir(
            "/Users/alex/code/my.app", projectDir: "-Users-alex-code-my-app"))
        XCTAssertFalse(ResumeSafety.cwdMatchesProjectDir(
            "/Users/alex", projectDir: "-Users-alex-code-my-app"))
    }

    // L3: the update link comes from a network response.
    func testUpdateLinkIsPinnedToThisReposReleases() {
        XCTAssertEqual(UpdateChecker.safeReleaseURL("https://github.com/jkkorn/Night-Conductor/releases/tag/v1.0.14"),
                       "https://github.com/jkkorn/Night-Conductor/releases/tag/v1.0.14")
        XCTAssertEqual(UpdateChecker.safeReleaseURL("https://evil.example/releases"), UpdateChecker.releasesPage)
        XCTAssertEqual(UpdateChecker.safeReleaseURL("file:///Applications/Calculator.app"), UpdateChecker.releasesPage)
        XCTAssertEqual(UpdateChecker.safeReleaseURL("https://github.com/someone-else/x/releases"), UpdateChecker.releasesPage)
        XCTAssertEqual(UpdateChecker.safeReleaseURL(nil), UpdateChecker.releasesPage)
    }
}
