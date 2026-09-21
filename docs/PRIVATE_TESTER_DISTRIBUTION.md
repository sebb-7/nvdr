# Invite-only FarRelay tester distribution

This design keeps the nvdr source repository private and does not use a public GitHub release repository.

The tester gateway uses Cloudflare Workers for the API, D1 for invitations/devices/channel state, and a private R2 bucket for installers and updater ZIPs. Do not enable a public R2 development URL or public bucket domain.

Authorization flow:
1. The administrator creates a one-time invitation.
2. The invitation returns an activation code and installer URL.
3. The installer URL only serves the current channel installer while the invitation is active.
4. During installation the tester enters the activation code.
5. farrelay-updater exchanges the code for a random device credential.
6. D1 stores only the SHA-256 hash of the credential.
7. Windows stores the raw credential encrypted with machine-scope DPAPI in C:\ProgramData\FarRelay\device.credential and restricts the file to SYSTEM and Administrators.
8. Every manifest and updater ZIP request requires the device credential.
9. Revoking a device blocks future downloads and updates. It intentionally does not remotely disable software already installed.

Cloudflare setup from distribution-gateway:
- npm install
- npx wrangler login
- npx wrangler r2 bucket create farrelay-private-releases
- npx wrangler d1 create farrelay-testers --binding DB --update-config
- npx wrangler d1 migrations apply farrelay-testers --remote
- npx wrangler deploy
- Generate a strong random admin token and pipe it to npx wrangler secret put ADMIN_TOKEN.

Record the HTTPS workers.dev URL printed by Wrangler. Use it as GatewayUrl.

The Windows Distribution Release workflow only creates a private build artifact. It no longer publishes to GitHub Releases.

Publish an artifact with windows\release\Publish-FarRelayPrivateRelease.ps1.

Create/revoke testers with windows\release\Manage-FarRelayTesters.ps1.

Keep FARRELAY_ADMIN_TOKEN only in your local environment or a secure CI secret. Never commit it.
