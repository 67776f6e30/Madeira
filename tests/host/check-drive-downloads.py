#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Compile and exercise Drive plans, ranges, persistence, disk assembly and ZIP install.

No Google account/network required. Linux uses OpenSSL for the CryptoKit MD5 adapter.
Run with Python 3 and swiftc (Linux also needs zlib/OpenSSL development headers).
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')
assert SWIFTC, 'swiftc is required; do not report compiled checks as passed without it'
project = (ROOT / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
names = ['DriveModels', 'DriveAuth', 'DriveAPI', 'DriveStorage', 'DriveDownloads', 'DriveGames']
for name in names:
    assert f'/* {name}.swift in Sources */,' in project, f'{name} missing from Sources'
    assert f'path = "{name}.swift"' in project
plist = plistlib.loads((APP / 'Info.plist').read_bytes())
client = plist['MadeiraGoogleClientID']
schemes = [s for entry in plist['CFBundleURLTypes'] for s in entry.get('CFBundleURLSchemes', [])]
assert '.'.join(reversed(client.split('.'))) in schemes, 'OAuth callback scheme must match client ID'
print('PASS: Xcode source registration and OAuth URL scheme')
subprocess.run([SWIFTC, '-frontend', '-parse', *[str(APP / (n + '.swift')) for n in names],
                *[str(APP / n) for n in ['MadeiraApp.swift', 'Library.swift', 'LibraryGridPage.swift', 'SettingsPages.swift']]], check=True)

with tempfile.TemporaryDirectory(prefix='madeira-drive-') as directory:
    work = Path(directory)
    (work / 'fixtures').mkdir()
    with zipfile.ZipFile(work / 'fixtures/game.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('Game/game.exe', b'MZtest')
        archive.writestr('Game/data.bin', b'payload')
    models = (APP / 'DriveModels.swift').read_text()
    api = (APP / 'DriveAPI.swift').read_text().replace('import Foundation', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif')
    storage = (APP / 'DriveStorage.swift').read_text()
    archive = (APP / 'SwiftItch/ItchArchive.swift').read_text().split('// MARK: .7z')[0]
    external = (APP / 'ExternalStorage.swift').read_text()
    paths = external[external.index('enum ExternalStoragePath {'):external.index('enum ExternalStorageIdentity {')]
    stubs = '''
import Foundation
enum DriveOAuth { static let clientID = "test.apps.googleusercontent.com"; static let redirect = "test:/oauthredirect"; static let scope = "https://www.googleapis.com/auth/drive.readonly" }
struct DriveCredential { var account: DriveAccount; var accessToken: String; var refreshToken: String; var expires: Date; var clientID: String }
enum DriveKeychain {
    nonisolated(unsafe) static var current: DriveCredential? = DriveCredential(account: DriveAccount(id: "a", email: "test"), accessToken: "access", refreshToken: "refresh", expires: Date().addingTimeInterval(3600), clientID: DriveOAuth.clientID)
    static func load() throws -> DriveCredential? { current }
    static func save(_ credential: DriveCredential) throws { current = credential }
    static func delete() throws { current = nil }
}
enum ExternalStorageError: Error { case unsafePath }
'''
    extra = []
    if sys.platform == 'linux':
        storage = storage.replace('import CryptoKit', 'import COpenSSL')
        stubs += '''
import COpenSSL
enum Insecure {
    struct MD5 {
        var context = MD5_CTX()
        init() { MD5_Init(&context) }
        mutating func update(data: Data) { data.withUnsafeBytes { _ = MD5_Update(&context, $0.baseAddress, $0.count) } }
        mutating func finalize() -> [UInt8] { var result = [UInt8](repeating: 0, count: 16); MD5_Final(&result, &context); return result }
    }
}
'''
        (work / 'module.modulemap').write_text('module COpenSSL [system] { header "/usr/include/openssl/md5.h" link "crypto" export * }\nmodule zlib [system] { header "/usr/include/zlib.h" link "z" export * }\n')
        extra = ['-I', str(work)]
    for name, text in [('Models', models), ('API', api), ('Storage', storage), ('Archive', archive), ('Stubs', stubs), ('Paths', 'import Foundation\n' + paths)]:
        (work / (name + '.swift')).write_text(text)
    sources = [str(p) for p in work.glob('*.swift')] + [str(ROOT / 'tests/host/drive-downloads/main.swift')]
    binary = work / 'checks'
    subprocess.run([SWIFTC, '-swift-version', '5', '-parse-as-library', *extra, *sources, '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(work / 'fixtures')], check=True)
    # Compile the production coordinator with host-only Apple API signatures.
    # Scheduling, cancellation and delegate code still need an iOS device test.
    manager = (APP / 'DriveDownloads.swift').read_text()
    for module in ['Combine', 'UIKit', 'UserNotifications', 'AuthenticationServices']:
        manager = manager.replace('import ' + module, '')
    manager = manager.replace('import Foundation', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif')
    manager = manager.replace('URLSessionConfiguration.background(withIdentifier: Self.sessionID)', 'URLSessionConfiguration.default')
    manager = manager.replace('config.sessionSendsLaunchEvents = true;', '')
    manager = manager.replace(', .completeFileProtectionUntilFirstUserAuthentication', '')
    manager = manager.replace('request.allowsExpensiveNetworkAccess = !wifiOnly', '')
    for line in ['task.countOfBytesClientExpectsToReceive = block.length', 'task.countOfBytesClientExpectsToSend = 1024']:
        manager = manager.replace(line, '')
    (work / 'Manager.swift').write_text(manager)
    subprocess.run([SWIFTC, '-swift-version', '5', '-typecheck', *extra,
                    *[str(p) for p in work.glob('*.swift')], str(ROOT / 'tests/host/drive-downloads/Platform.swift')], check=True)
    print('PASS: download coordinator type-check with host platform signatures (not an iOS build)')
