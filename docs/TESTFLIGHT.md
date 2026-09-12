# FarRelay internal TestFlight distribution

The manual **TestFlight** GitHub Actions workflow creates one signed Release
archive for `FarRelay` (`com.sebb7.farrelay`), exports an App Store Connect IPA,
and uploads it using an App Store Connect API key. It runs only from **Run
workflow**; ordinary push and pull-request CI remains unsigned simulator
validation.

## One-time Apple setup

Create or verify these resources before running the workflow:

| Location | Required resource/value | GitHub secret | Sensitive | Regenerable |
| --- | --- | --- | --- | --- |
| Apple Developer → Certificates, Identifiers & Profiles → Identifiers | App ID `com.sebb7.farrelay` owned by Sebastian's team | — | No | N/A |
| Apple Developer → Certificates, Identifiers & Profiles → Certificates | **Apple Distribution** certificate, exported as a password-protected `.p12` | `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Yes | Yes; revoke/reissue if needed |
| Apple Developer → Certificates, Identifiers & Profiles → Profiles | App Store Connect provisioning profile for `com.sebb7.farrelay`, downloaded as `.mobileprovision` | `APPLE_PROVISIONING_PROFILE_BASE64` | Yes | Yes; create/download a replacement |
| Apple Developer → Membership | Sebastian's 10-character Apple Team ID | `APPLE_TEAM_ID` | No | No; copy from Membership |
| App Store Connect → Users and Access → Integrations → App Store Connect API | API key with permission to upload builds; download its `.p8` once | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | Key ID/issuer: no; `.p8`: yes | `.p8` is not recoverable; revoke and create a new key if lost |

Encode the certificate and provisioning profile as one-line base64 before adding
their GitHub Actions secrets. Store `ASC_PRIVATE_KEY` as the complete `.p8`
text, including its header and footer. Never commit or paste any of these
materials into repository files, issues, or chat.

The workflow verifies that the profile's team equals `APPLE_TEAM_ID`, its App ID
equals `APPLE_TEAM_ID.com.sebb7.farrelay`, and the imported certificate is an
Apple Distribution identity before archiving.

## App Store Connect app record

Before the first upload, create or select the App Store Connect app at **Apps →
Add (+) → New App** with:

- Platform: iOS
- Name: FarRelay
- Primary language: English (U.S.)
- Bundle ID: `com.sebb7.farrelay`
- SKU: `FARRELAY-IOS`

If **FarRelay** is unavailable, stop: do not rename the product or invent an
alternative name in this workflow.

Use internal TestFlight only for the first build. Do not configure external
testers, beta review, App Store submission, pricing, screenshots, or production
metadata in this milestone.

## Running a build

In GitHub, open **Actions → TestFlight → Run workflow**, select
`chore/farrelay-testflight` (or the eventual release branch), and run it
manually. The build number is GitHub's monotonically increasing
`github.run_number`; marketing version remains `1.0.0` in `ios/project.yml`.

Successful upload means App Store Connect accepted the IPA. TestFlight may still
need time to process the build before it becomes installable on Sebastian's
iPad.
