#!/usr/bin/env python3
"""Exercise the actual launch cancellation/close methods with native boundaries stubbed.

Needs swiftc. --source-only checks UI/async wiring when no Swift toolchain is available.
No Wine processes, credentials, or UI are used.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
library = (root / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
content = (root / 'app/Madeira/ContentView.swift').read_text(encoding='utf-8')


def block(text, header):
    start = text.index(header)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print('PASS: ' + message, flush=True)


recovery = block(library, 'private func launchRecovery(')
for layout in ('launchColumnView', 'launchWideView'):
    view = block(library, f'private func {layout}(')
    check('launchRecovery(entry)' in view and 'ScrollView' in view,
          f'{layout}: recovery actions are reachable on short screens')
check('model.stopLaunch()' in recovery and '.disabled(model.stoppingLaunch)' in recovery,
      'loading and failed launches have a labelled stop action with duplicate taps disabled')
check('model.forceCloseOffered' in recovery and 'model.closeMadeira()' in recovery,
      'timeout exposes app closure on the starting screen itself')
check('ClaudeHelpButton(entry: entry)' in recovery and 'dockStart.failure != nil' in recovery,
      'failed launches share the active game through the existing Claude help button')
check('ClaudeHelp.files(for: model.helpEntry)' in library and '.sheet(item: $errorHelpFiles)' in library,
      'errors returning to the library also offer help with the retained game')
check('guard !stoppingLaunch' in block(library, 'func showGameView(')
      and 'if pollLaunchStop() { return }' in block(library, 'private func poll()'),
      'late frames and Dock auto-reveal cannot hide recovery during shutdown')
check('guard requestID == library.launchRequestID' in block(content, 'private func launchAfterJITEnded('),
      'JIT completion rejects a cancelled request before reporting or launching')
for call in ('EALibrary.shared.prepareLaunch(entry)', 'EpicLibrary.shared.launchArguments(appName: app)',
             'SteamOwnedLibrary.shared.settleCloud(appID)', 'SteamOwnedLibrary.shared.launchOptions(appID: game.id)',
             'SteamOwnedLibrary.shared.prepareDock()'):
    tail = content[content.index('await ' + call):].splitlines()[1:3]
    check(any('launchRequestID == requestID' in line for line in tail),
          f'cancelled async completion cannot launch: {call}')
check('guard model.launchRequestID == requestID' in library,
      'the delayed Play animation cannot restart a cancelled launch')
check(content.count('library.beginLaunchPreparation()') == 4
      and content.count('library.endLaunchPreparation()') == 4,
      'async preparation keeps recovery visible until shared resources have been released')
sequence = block(content, 'private func runWineFullSequence(')
check(sequence.count('if cancelBeforeWine() { return }') == 4
      and 'DispatchQueue.main.async { library.nativeLaunchSettled() }' in sequence,
      'native startup checks cancellation between stages and acknowledges Wine startup')
check('wineserver_stop()' in block(sequence, 'func cancelBeforeWine()')
      and 'DispatchQueue.global' in sequence,
      'cancelling native startup waits for server teardown off the UI thread')
strings = json.loads((root / 'app/Madeira/Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
for key in ('Cancel launch', 'Stop and return to library', 'Stopping session…',
            'Returning to the library when the session closes…',
            'The session did not close. Close Madeira and open it again to return to the library.'):
    check(bool(strings[key]['localizations']['ko']['stringUnit']['value']), f'Korean recovery text: {key}')

if '--source-only' in sys.argv:
    print('SKIP: Swift behavior checks (--source-only)')
    sys.exit(0)

methods = '\n'.join(block(library, header).replace('private func', 'func', 1) for header in (
    'private func pollLaunchStop()', 'func stopLaunch()', 'func nativeLaunchSettled()',
    'func beginLaunchPreparation()', 'func endLaunchPreparation()', 'private func finishPreparationCancellation()'))
swift = r'''
import Foundation
var wine: Int32 = 0, server: Int32 = 0, desktopCloses = 0
func wine_process_is_running() -> Int32 { wine }
func wineserver_is_running() -> Int32 { server }
func winios_close_desktop() { desktopCloses += 1 }
enum LibraryKeyboard { static func hide() {} }
class LogStore { static let shared = LogStore(); func log(_ text: String) {}; func setDisplayActive(_ active: Bool) {} }
class LaunchCurtain { static let shared = LaunchCurtain(); var cancelled = 0; func cancel() { cancelled += 1 } }
class DockStartScreen { static let shared = DockStartScreen(); var active = false }
struct Entry { var desktop: Bool? = nil; var runsInDesktop = false }
class LibraryModel {
    static let forceCloseAfter: TimeInterval = 10
    var stoppingLaunch = false, nativeLaunchPending = false, launchCloseSent = false
    var launchPreparations = 0
    var timer: Timer?
    var forceCloseOffered = false, quitRequested = false, menu = false
    var launchLogs = false
    var quitRequestedAt: Date?
    var launchRequestID = UUID(), startingJIT: UUID? = UUID()
    var current: UUID?, preparing: String? = "Game", activeEntry: Entry?
    var cloudRetry: (() -> Void)?, cloudBypass: Int?
    var finished = 0, altF4 = 0
    func finish() { finished += 1; current = nil; stoppingLaunch = false }
    func requestQuit() { altF4 += 1 }
    func poll() { _ = pollLaunchStop() }
''' + methods + r'''
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    print("PASS: " + message)
}

let prep = LibraryModel()
let oldRequest = prep.launchRequestID
prep.cloudRetry = {}; prep.cloudBypass = 10
prep.stopLaunch()
expect(prep.preparing == nil && prep.startingJIT == nil && prep.cloudRetry == nil && prep.cloudBypass == nil,
       "cancelling preparation clears queued JIT and cloud launch state")
expect(prep.launchRequestID != oldRequest && LaunchCurtain.shared.cancelled == 1,
       "cancelled requests stay invalid, including when the same game is selected again")
expect(!prep.stoppingLaunch && prep.finished == 0, "preparation cancellation needs no native teardown")

let signIn = LibraryModel()
signIn.beginLaunchPreparation()
signIn.stopLaunch()
expect(signIn.stoppingLaunch && signIn.preparing != nil,
       "pending sign-in retains recovery until its connection handoff can unwind")
signIn.quitRequestedAt = Date().addingTimeInterval(-11); signIn.poll()
expect(signIn.forceCloseOffered, "stuck sign-in preparation offers app closure too")
signIn.endLaunchPreparation()
expect(signIn.preparing == nil && !signIn.stoppingLaunch && !signIn.forceCloseOffered,
       "cancelled sign-in returns after cleanup and resets its timeout UI")

let pending = LibraryModel()
pending.current = UUID(); pending.nativeLaunchPending = true
pending.stopLaunch()
expect(pending.stoppingLaunch && pending.finished == 0, "zero native flags do not end a still-queued launch")
let requestedAt = pending.quitRequestedAt
pending.stopLaunch()
expect(pending.quitRequestedAt == requestedAt, "repeated stop does not postpone the timeout")
pending.quitRequestedAt = Date().addingTimeInterval(-11)
pending.poll()
expect(pending.forceCloseOffered && pending.finished == 0, "blocked startup offers Close Madeira after ten seconds")
pending.nativeLaunchSettled()
expect(pending.finished == 1, "cancelled startup returns only after its worker acknowledges cancellation")

let dock = LibraryModel()
dock.current = UUID(); dock.nativeLaunchPending = true
DockStartScreen.shared.active = true
wine = 1; server = 1
dock.stopLaunch()
expect(desktopCloses == 0, "close is not posted before Wine's session reset")
dock.nativeLaunchSettled()
expect(desktopCloses == 1 && dock.altF4 == 0, "Dock cancellation targets the desktop, not a dead foreground window")
dock.poll()
expect(desktopCloses == 1, "desktop close is posted once")
wine = 0; dock.poll()
expect(dock.finished == 0, "Wine exiting alone cannot return while the server still runs")
server = 0; dock.poll()
expect(dock.finished == 1, "the ended Dock session returns to the library")

DockStartScreen.shared.active = false
let direct = LibraryModel()
direct.current = UUID(); wine = 1; server = 1
direct.stopLaunch()
expect(direct.altF4 == 1, "a direct game receives its normal close request")
direct.quitRequestedAt = Date().addingTimeInterval(-11); direct.poll()
expect(direct.forceCloseOffered && direct.finished == 0, "an unresponsive direct game keeps recovery visible")
server = 0; direct.poll()
expect(direct.finished == 0, "a still-running game cannot be abandoned")
wine = 0; direct.poll()
expect(direct.finished == 1, "a direct game returns only when both native flags are clear")

let desktop = LibraryModel()
desktop.current = UUID(); desktop.activeEntry = Entry(desktop: true)
wine = 1; server = 1; desktop.stopLaunch()
expect(desktopCloses == 2 && desktop.altF4 == 0, "ordinary desktop launches use explicit desktop closure too")
print("PASS: all launch recovery behavior checks")
'''
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    sys.exit('swiftc is required for behavior checks; use --source-only for wiring checks')
with tempfile.TemporaryDirectory(prefix='madeira-launch-recovery-') as folder:
    source = Path(folder) / 'recovery.swift'
    exe = Path(folder) / ('recovery.exe' if os.name == 'nt' else 'recovery')
    source.write_text(swift, encoding='utf-8')
    subprocess.run([compiler, '-swift-version', '5', str(source), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
