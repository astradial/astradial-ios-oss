# Security Policy

- Report vulnerabilities privately to security@astradial.com — do not open public issues.
- Never commit credentials: real `GoogleService-Info.plist` is enforced-local (git skip-worktree); `.env*`, `*-sa-key.json`, `*credentials*.json` are gitignored; TruffleHog runs on every push/PR.
- Flow: every change goes **upstream → OSS → private**. `astradial-ios-oss`
  (branch `astradial`) is the primary development repo for ALL app code;
  the private repo's `private-main` is a downstream overlay (OSS merge +
  private-only commits such as internal tooling). Nothing is developed
  private-first except material that must never be public.
