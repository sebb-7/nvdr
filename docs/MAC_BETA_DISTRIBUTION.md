# FarRelay Mac Beta distribution

FarRelay Mac Beta 0.1 is a direct-distribution Developer ID application. It
is not an App Store or TestFlight host build: global input capture, synthetic
input, Accessibility permissions, the speech provider, and local host IPC are
owned by the signed app in the logged-in user session.

## One-time Apple Developer setup

1. Create the Mac App ID `com.sebb7.farrelay`.
2. Create App Group `group.com.sebb7.farrelay` and attach it to FarRelay and
   `com.sebb7.farrelay.remotevoice` when Apple’s portal requests the extension
   registration.
3. Create and privately export a **Developer ID Application** certificate as a
   password-protected `.p12`.
4. Create an App Store Connect API key that can notarize. Record its Key ID and
   Issuer ID; download its `.p8` file once.
5. Create GitHub Actions secrets: `APPLE_TEAM_ID`,
   `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`,
   `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`, `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY`.

Never commit a certificate, profile, private key, password, or Team ID.

## Every beta build

Run the manual **FarRelay Mac Beta** workflow with a build number larger than
all previously distributed Mac builds. It builds universal helper slices,
embeds the helper, verifies nested code, notarizes and staples the app and DMG,
runs Gatekeeper assessment, then uploads `FarRelay.dmg` as an artifact.

Marketing version is `0.1.0`; the numeric build number is monotonically
increasing. Ordinary `macos-ci.yml` stays unsigned and credential-free.

## Future TestFlight client

A separate sandboxed FarRelay Client may eventually offer controller and
terminal features through TestFlight. It must never claim full host support
unless every capture, injection, provider, and IPC requirement is physically
validated within App Sandbox. Beta 0.1 intentionally ships one direct app.
