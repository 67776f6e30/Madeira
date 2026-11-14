# Google Drive

Madeira can connect to a Google account, browse a chosen Drive folder, and
download ZIP files or complete game folders. Downloads use an iOS background
URLSession and keep completed byte ranges on disk for resuming. ZIP extraction
and installation finish while Madeira is open. Games install under
`Madeira/wine/drive_c/Google Drive/game-<download UUID>`.

## Configure Google OAuth before building

The repository contains placeholders, not working Google credentials. Configure
these once for your app build; users only sign in and grant access in the app.

1. Create a Google Cloud project and enable **Google Drive API**.
2. Configure the OAuth consent screen and request `openid`, `email`, and
   `https://www.googleapis.com/auth/drive.readonly`. Add your Google account as a
   test user while the app is in Testing.
3. Create an **iOS** OAuth client for the bundle identifier of the installed app.
   Check the actual identifier after your sideloading tool signs the IPA.
4. In [Info.plist](../app/Madeira/Info.plist), set the value of
   `MadeiraGoogleClientID` to the client ID, for example
   `123456789-example.apps.googleusercontent.com`.
5. In the same file's `CFBundleURLTypes`, replace
   `com.googleusercontent.apps.YOUR_IOS_CLIENT_ID` with the reversed client ID,
   for example `com.googleusercontent.apps.123456789-example`.
6. Rebuild and install the IPA. The redirect URI used by this implementation is
   `<reversed-client-id>:/oauthredirect`. A missing/mismatched scheme or an
   unchanged placeholder produces a configuration message when signing in.

No client secret or service account key belongs in the app. This implementation
uses `ASWebAuthenticationSession`, authorization code + PKCE (S256), and state
validation. Tokens are exchanged directly with Google and stored in a
non-synchronizing, device-only Keychain item accessible after the first unlock.
Tokens are not written to the download queue or logs. It does not require a
Google SDK or a proxy server. See Google's [iOS client configuration](https://developers.google.com/identity/sign-in/ios/api-access)
and [OAuth native app flow](https://developers.google.com/identity/protocols/oauth2/native-app).

`drive.readonly` is a restricted scope that grants account-wide read access;
selecting a folder controls which content Madeira shows and downloads, rather
than narrowing that OAuth grant. Public distribution must satisfy Google's
[scope verification requirements](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
External apps in Testing using Drive scopes have the documented
[seven-day refresh-token expiration](https://developers.google.com/identity/protocols/oauth2#expiration).

## Use the connection

Open **Settings > Google Drive** or the library's **Drive** tab and choose
**Browse & Downloads**. Sign in, navigate through Drive folders, and press
**Use this folder**. This folder is remembered for the next visit.

Use the download button beside a ZIP/folder, or **Download this folder as a
game** inside the game folder. A folder is enumerated recursively with all
listing pages before the download starts. Regular files retain their relative
paths; empty directories are preserved. Shortcuts, Google Workspace documents,
unrepresentable Windows paths, and duplicate local paths are rejected rather
than silently omitted. A job is limited to 100,000 items, 10,000 folders, 64 path
components and 8 TB.

Completed installations with one executable are registered automatically. With
several EXE/BAT/CMD files, select the launch program in Downloads. You can change
the program later. Installation does not run setup executables automatically.
Games without a detected program remain on disk for manual registration.
Downloaded games do not require a Google sign-in to play.

## Background downloads and resuming

Transfers use a single stable background session and at most eight outstanding
128 MiB range requests. Each successfully validated range is moved into durable
storage before being considered complete. **Pause** preserves completed ranges;
**Resume** rechecks remote file metadata and requests the missing ranges using
fresh credentials. A partial in-flight range may be downloaded again, bounded
by 128 MiB; this does not restart already completed ranges or files.

The queue and saved blocks are restored after an app relaunch. A manually paused
job stays paused. Normal backgrounding or screen locking leaves transfers with
the OS. Force-quitting the app cancels OS transfers; reopening restores the queue.
Network, battery, iOS scheduling and token refresh availability can delay progress.
Retries use bounded exponential backoff; a task that cannot recover remains
visible with a Resume button. An account mismatch requires the original account.
See [Apple background session behavior](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)).

Wi-Fi-only downloads are enabled by default. Changing the setting cancels
in-flight ranges and schedules replacements with the new network policy.
Disconnect pauses downloads and clears the local credential. It keeps installed
games and saved ranges. Google account access can also be revoked in Google's
account settings.

The download delegate validates HTTP status, byte count and `Content-Range`.
Final assembly streams data through an MD5 check when Drive supplies a checksum.
The file's version/size/checksum metadata is checked before resumed requests and
before installation; a changed source requires cancelling and starting a new job.
The ZIP reader additionally checks CRC and rejects unsafe archive entries.

Blocks are retained until installation succeeds. Reserve temporary storage:
roughly **twice the ZIP size plus the extracted game**, or **twice the total
game-folder size**, plus headroom. The installer checks free space before file
assembly and extraction. Interrupted installation restarts using saved blocks;
it does not download the whole game again. Completed installs use a new UUID
folder, so they do not overwrite an existing game or its saves.

## Source and checks

- `DriveAuth.swift`: placeholders, PKCE/system browser and Keychain.
- `DriveAPI.swift`: OAuth exchange/refresh, file metadata, paginated recursive
  folder listing, authenticated range requests.
- `DriveModels.swift`: durable jobs, range identity/validation and path rules.
- `DriveStorage.swift`: saved ranges, streaming assembly, checksums and install.
- `DriveDownloads.swift`: background session lifecycle, queue, retry, pause,
  cancel, restoration and installation coordination.
- `DriveGames.swift`: folder browser, account settings, download controls and
  library registration.

Run `python3 tests/host/check-drive-downloads.py` on a host with Swift. On Linux,
install the zlib and OpenSSL development headers; the host-only MD5 adapter uses
OpenSSL. The suite compiles real models/API/storage code and exercises range
validation, large offsets, persistence, account isolation, recursive pagination,
checksums, ZIP extraction and folder installation with mocked HTTP responses.
It also parses all changed Swift sources and type-checks the coordinator with
host platform signatures. This is not an iOS SDK build.

Before release, build with Xcode and test a real OAuth client on a signed iPhone:
login cancellation/denial, ZIP over 4 GB, many-file folders, screen locking,
network loss, expired access/refresh tokens, OS termination versus force quit,
Wi-Fi/cellular policy, low disk space, interruption during extraction, and
multiple program selection. No live OAuth or iOS background transfer test can
be completed with the placeholder credentials.
