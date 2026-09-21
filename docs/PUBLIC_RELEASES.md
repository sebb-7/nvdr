# Public FarRelay release channels

FarRelay source may remain private. Windows installers and updater payloads are published separately to the public repository `sebb-7/farrelay-releases`.

## One-time public repository setup

Run while authenticated with GitHub CLI:

```powershell
gh repo create sebb-7/farrelay-releases --public --description "Public FarRelay installers and update channel metadata" --add-readme
```

FarRelay does not contain or persist a GitHub credential. Installed clients trust only release assets below:

`https://github.com/sebb-7/farrelay-releases/releases/download/`

## Release channels

The rolling channel tags are:

- `farrelay-beta`
- `farrelay-stable`

The installer stores the matching manifest URL in `C:\ProgramData\FarRelay\install.json`. The updater downloads `update-beta.json` or `update-stable.json`, validates the selected archive's size and SHA-256, stages the fixed FarRelay executables, and retains a rollback copy.

## Publish directly from CI

The private source repository's `Windows Distribution Release` workflow can publish to the public repository when `publish_release=true`.

The default GitHub Actions token cannot write across repositories. Configure a repository secret named `FARRELAY_RELEASE_TOKEN` using a fine-grained GitHub token limited to `sebb-7/farrelay-releases` with repository Contents read/write permission. Never embed or commit the token.

Build-only workflow runs with `publish_release=false` do not require this secret.

## Publish locally without a CI token

Run the distribution workflow with `publish_release=false`, download its artifact, then use the existing GitHub CLI login:

```powershell
.\windows\release\Publish-FarRelayPublicRelease.ps1 -Channel beta -DistributionDirectory .\FarRelay-Windows-0.2.0-beta.2
```

The script creates the rolling release if necessary and uploads the generated distribution assets with replacement enabled.
