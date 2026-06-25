# Packaging & distribution

Signing only affects the **binaries you ship**; the source stays MIT and
contributors keep building ad-hoc from source for free. Your account:
Apple ID `jkkorn@mac.com`, Team ID `Q7DSDANFTU`.

The whole setup is about ten minutes, once. After that, every release is a
single `./release.sh`.

## Why signing is worth the $99/yr

The app is genuinely held back while it is unsigned, because an ad-hoc
signature gets a brand new identity on every build:

- **macOS stops warning people.** No "unidentified developer" block and no
  `xattr -dr com.apple.quarantine` dance. People download, unzip, and open.
- **The Accessibility grant sticks.** The faithful in-app resume (pressing
  Retry inside Conductor or the Claude app, so the chat stays in sync) needs
  Accessibility, and macOS ties that grant to the app's identity. Ad-hoc builds
  lose it on every reinstall; a Developer ID identity is stable, so you grant
  it once and updates keep it.
- **The Keychain prompt happens once.** Reading the Claude sign-in is tied to
  the same stable identity, so clicking "Always Allow" actually holds.

## One-time setup

### 0. Renew the Apple Developer membership
It is currently expired. Renew it in the **Apple Developer** app (Account →
Renew), or at developer.apple.com/account, for $99/yr. The certificate in the
next step cannot be created until the membership is active again.

### 1. Create a "Developer ID Application" certificate
You currently have only an *Apple Development* cert, which can't sign apps for
distribution outside the App Store. Create the Developer ID one:

- **Xcode** → Settings → Accounts → select `jkkorn@mac.com` → **Manage
  Certificates…** → **+** → **Developer ID Application**.

Confirm it landed:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```
`build-app.sh` auto-detects it from then on (hardened runtime, timestamp).

### 2. Store notarytool credentials
Create an app-specific password at appleid.apple.com → Sign-In and Security →
App-Specific Passwords. Then store it once (run in your terminal — the
password never leaves your machine):
```bash
xcrun notarytool store-credentials night-conductor \
  --apple-id jkkorn@mac.com --team-id Q7DSDANFTU --password <app-specific-password>
```

## Cut a release
```bash
cd NightConductor
./release.sh          # build → sign → notarize → staple → zip + print sha256
```
Then publish it and wire the cask (the script prints both commands):
```bash
gh release create vX.Y.Z "dist/Night-Conductor-X.Y.Z.zip" --generate-notes
# put version + sha256 into packaging/night-conductor.rb
```

### Confirm it really is notarized
```bash
spctl -a -vvv "dist/Night Conductor.app"   # expect: accepted, source=Notarized Developer ID
```

### If something goes wrong
- **"is not Developer ID signed"** from `release.sh`: the cert is not in your
  keychain. Redo step 1 in Xcode, then check
  `security find-identity -v -p codesigning`.
- **Notarization comes back "Invalid":** read the reason with
  `xcrun notarytool log <submission-id> --keychain-profile night-conductor`.
- **App fails to launch after signing** (hardened runtime): re-run with a
  console attached to see the killed entitlement, then add an entitlements
  file to the `codesign` call in `build-app.sh`. A plain SwiftUI menu bar app
  like this one normally needs none.

## Homebrew
Create a tap repo `jkkorn/homebrew-tap`, add `Casks/night-conductor.rb`
(from `packaging/night-conductor.rb`). Users then:
```bash
brew install --cask jkkorn/tap/night-conductor
```

## Pay-what-you-want (optional, funds the $99/yr cert)
Keep the app free + open from source; offer the prebuilt notarized download
as pay-what-you-want (the Ice / Rectangle model).
