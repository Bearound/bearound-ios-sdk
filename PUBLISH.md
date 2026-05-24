# Publishing a New Version of BearoundSDK (iOS)

## Prerequisites

- Write access to the [Bearound/bearound-ios-sdk](https://github.com/Bearound/bearound-ios-sdk) repository
- CocoaPods trunk configured on your Mac (`pod trunk register`)
- CocoaPods trunk token stored in GitHub Secrets as `COCOAPODS_TRUNK_TOKEN`

---

## Step-by-step

### 1. Update the version in 3 files

The version must be identical in all three locations:

| File | Where | Example |
|------|-------|---------|
| `BearoundSDK/BearoundSDK.swift` | Line 21: `return "X.Y.Z"` | `return "3.0.0"` |
| `BearoundSDK.podspec` | `spec.version = "X.Y.Z"` | `spec.version = "3.0.0"` |
| `CHANGELOG.md` | `## [X.Y.Z] - YYYY-MM-DD` | `## [3.0.0] - 2026-05-24` |

### 2. Update CHANGELOG.md

Add a new section at the top of the file (just below the header) using this format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- Description of new features

### Changed
- Description of changes

### Fixed
- Description of bug fixes

---
```

> The workflow validates that `## [X.Y.Z]` exists in CHANGELOG.md. If it does not, the release fails.

### 3. Commit and push

```bash
git add BearoundSDK/BearoundSDK.swift BearoundSDK.podspec CHANGELOG.md
git commit -m "bump: version X.Y.Z"
git push origin main
```

### 4. Create and push the tag

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

> Pushing the tag (`v*`) automatically triggers the **iOS SDK Release** workflow on GitHub Actions.

### 5. Watch the workflow

The workflow runs 4 jobs in sequence:

```
1. Pre-Release Validation
   - Verifies tag version == podspec == changelog
   - Runs pod lib lint
   - Builds the XCFramework

2. Publish to CocoaPods
   - Checks whether the version is already published (skipped if it is)
   - Runs pod trunk push

3. Create GitHub Release
   - Creates the release on GitHub with notes from the CHANGELOG
   - Attaches XCFramework.zip as a release asset

4. Release Success
   - Confirms every job passed
```

Follow it at: https://github.com/Bearound/bearound-ios-sdk/actions

### 6. (Fallback) Publish manually to CocoaPods

If the CocoaPods step in the workflow fails, publish manually from your Mac:

```bash
pod trunk push BearoundSDK.podspec --allow-warnings --skip-import-validation --synchronous
```

> Requires `COCOAPODS_TRUNK_TOKEN` configured or an active session via `pod trunk register`.

---

## Quick Checklist

```
[ ] Version updated in BearoundSDK.swift
[ ] Version updated in BearoundSDK.podspec
[ ] CHANGELOG.md updated with a section for the new version
[ ] Commit and push to main
[ ] Tag created: git tag vX.Y.Z
[ ] Tag pushed: git push origin vX.Y.Z
[ ] Workflow green on GitHub Actions
[ ] Version visible on CocoaPods (pod search BearoundSDK)
```

---

## Common Errors

### "Version mismatch between tag and podspec"
The version in the tag (`vX.Y.Z`) does not match `spec.version` in the podspec. Fix the podspec, commit, then delete and recreate the tag:
```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
# fix the podspec, commit, push
git tag vX.Y.Z
git push origin vX.Y.Z
```

### "Version X.Y.Z not documented in CHANGELOG.md"
The `## [X.Y.Z]` section is missing from CHANGELOG.md. Add it, commit, then delete and recreate the tag.

### "Authentication token is invalid or unverified"
The `COCOAPODS_TRUNK_TOKEN` GitHub Secret has expired. Generate a new one:
```bash
pod trunk register email@example.com 'Name' --description='GitHub Actions'
# Confirm via email
# Copy the token from ~/.netrc
```
Update the secret at: Settings > Secrets and variables > Actions > `COCOAPODS_TRUNK_TOKEN`

### "Version already published on CocoaPods"
The workflow detects this automatically and skips `pod trunk push`. Not an error.

### Tag conflicts with a branch of the same name
Use the full refspec:
```bash
git push origin refs/tags/vX.Y.Z
```

---

## Versioning

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR** (X.0.0): breaking changes to the public API
- **MINOR** (0.X.0): new features without breaking compatibility
- **PATCH** (0.0.X): bug fixes and internal improvements
