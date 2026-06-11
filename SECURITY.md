# Security Policy

- Report vulnerabilities privately to security@astradial.com — do not open public issues.
- Never commit credentials: real `GoogleService-Info.plist` is enforced-local (git skip-worktree); `.env*`, `*-sa-key.json`, `*credentials*.json` are gitignored; gitleaks runs on every push/PR.
- The public repo (astradial-ios-oss) only receives curated pushes from the private repo after CI + secret scan pass.
