# App Review risk audit

Audit of Plume against the App Review Guidelines before the first submission
(iOS, iPadOS, macOS). Each risk lists where it is and what was done. Status:
**fixed** (in this branch), **ok** (nothing to do, checked), **open** (needs
someone outside the code).

## 2.1 App completeness

| # | Risk | Where | Fix | Status |
|---|---|---|---|---|
| 1 | A self-signed or expired certificate shows "The server can't be reached", which reads like a network problem | `NextcloudClient.send`, `LoginFlow.start` | Certificate errors get their own message, telling the user to use a certificate from a recognized authority | fixed |
| 2 | A server in maintenance mode (503) shows "HTTP 503" | `NextcloudClient.check` | Maintenance is recognized (`X-Nextcloud-Maintenance-Mode`) and explained | fixed |
| 3 | 403 shows "HTTP 403" | `NextcloudClient.check` | Explained as missing permission | fixed |
| 4 | A revoked app password (401) raises the same alert on every folder opened and every minute, with no way out | `AppModel.report` | One prompt, "Sign In Again", which signs out and keeps the server address | fixed |
| 5 | Signing in with the account password when two-factor authentication is on fails with a generic refusal | `LoginView` | The app password path explains that an app password is needed, and the browser sign-in (which handles two-factor) is the default | fixed |
| 6 | A non-Nextcloud address shows "Unexpected server response: this doesn't look like a Nextcloud server" | `LoginFlow.start` | Plain message, with the address format to use | fixed |
| 7 | Timeout and offline | `PlumeError.offline`, `FolderView` banner | Already handled: cached contents shown with an offline banner | ok |
| 8 | Quota full (507) | `PlumeError.insufficientStorage` | Already explained; the upload stays in the outbox | ok |
| 9 | Placeholder text, dead buttons | all views | None found; every button acts | ok |

## Reviewer access (2.1, 4.2)

| # | Risk | Fix | Status |
|---|---|---|---|
| 10 | The reviewer has no Nextcloud server and doesn't know what to type | The first screen gets a "What is Nextcloud?" explanation and link, and a line saying a server address is needed | fixed |
| 11 | Demo account | Review notes with the demo server, login and the steps of the browser sign-in; the account itself is provided by the owner | open (owner provides the server and account) |
| 12 | 4.2 minimum functionality | Plume is a full client (browse, search, Spotlight, Files/Finder, offline, upload, share, versions, trash); the notes list what to try | ok |

## 5.1 Privacy

| # | Risk | Where | Fix | Status |
|---|---|---|---|---|
| 13 | 5.1.1(v) account deletion | — | No Plume account exists; the user's Nextcloud account is managed by their server. Stated in the review notes | ok |
| 14 | Sign-out leaves data behind: thumbnails, the File Provider extension's database, version previews | `AppModel.signOut` | Sign-out also removes the thumbnails, every metadata database in the app group, temporary files and the shared pinned list | fixed |
| 15 | Privacy manifest | `Config/PrivacyInfo.xcprivacy` (app and both extensions) | UserDefaults and file timestamps declared. Disk space and system boot time APIs aren't used, so they aren't declared | ok |
| 16 | Nutrition label | App Store Connect | "Data Not Collected": nothing leaves the device except to the user's own server | open (set in App Store Connect) |
| 17 | Privacy policy URL | https://plume.bonout.com/privacy/ | Live | ok |
| 18 | Usage strings | `project.yml` | Plume talks to servers on the local network (`NSAllowsLocalNetworking`), which triggers the Local Network prompt on iOS: `NSLocalNetworkUsageDescription` added in English and French. No camera, photo library, Face ID or location use, so no other strings | fixed |

## Extensions

| # | Risk | Where | Fix | Status |
|---|---|---|---|---|
| 19 | A 50,000-item folder is reported to Finder / Files in one batch, all in memory in the extension | `Enumerator.enumerateItems` | Reported in pages of 500 from the local database; not yet measured with 50,000 items | fixed, to measure |
| 20 | Large uploads from the share extension | `ShareModel`, chunked upload | Files are copied to the group container and sent in 16 MB chunks, so memory shouldn't grow with file size; not yet measured with a 2 GB file | to measure |
| 21 | Signing and app groups | `project.yml`, entitlements | App and both extensions share the app group, signed for distribution by TestFlight builds | ok |

## Networking (ATS)

| # | Risk | Fix | Status |
|---|---|---|---|
| 22 | Arbitrary loads | Not used. Only `NSAllowsLocalNetworking`, for servers at home (`.local` names, private addresses), which App Review accepts without justification | ok |
| 23 | Self-signed certificates | Not trusted, no bypass: the error explains it (see 1) | ok |

## macOS

| # | Risk | Fix | Status |
|---|---|---|---|
| 24 | Sandbox, hardened runtime, entitlements | App Sandbox, network client, user-selected read-write, app group, keychain group; hardened runtime on | ok |
| 25 | macOS 15 | Deployment target 15.0 | ok |

## Other

| # | Risk | Fix | Status |
|---|---|---|---|
| 26 | Export compliance | `ITSAppUsesNonExemptEncryption = NO` (HTTPS only) | ok |
| 27 | 5.2 trademark | Name "Plume: Files for Nextcloud" (factual "for"), own icon, no Nextcloud logo in screenshots; the description says "Not affiliated with Nextcloud GmbH" | ok |
| 28 | VoiceOver: row icons read as symbol names, star unlabeled, rows read in pieces | `ItemRow` | Icons hidden, favorite labeled, each row read as one element | fixed |
| 29 | Dynamic Type, dark mode, iPad orientations and multitasking, Mac window resizing | System fonts and colors, all orientations, resizable window with a minimum size | ok |
| 30 | App UI is English only while the listing is also in French | — | Acceptable; French localization of the app is a later step | open |
