# Cloudflare Worker bootstrap relay

The Worker stores **no Apple API private key**. It only receives a UDID from `PikminPilotSetup.exe`, triggers the private GitHub registration workflow, and later exposes the freshly published IPA URL.

Configure secrets:

```bash
wrangler secret put GITHUB_TOKEN
wrangler secret put REGISTRATION_SHARED_TOKEN
```

`GITHUB_TOKEN` needs permission to dispatch Actions workflows in the Pikmin-Pilot repository. Keep it only in Worker secrets.

`REGISTRATION_SHARED_TOKEN` is an onboarding gate. It is less sensitive than your Apple/GitHub admin credentials but can still be extracted if you ship it inside `setup-config.json`; for larger distribution use per-user codes/rate limiting instead of one permanent shared token.

Deploy:

```bash
wrangler deploy
```

Then put the Worker URL into the Windows `setup-config.json`.
