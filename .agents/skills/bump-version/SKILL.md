---
name: bump-version
description: Clear the current repository's local dist folder, bump its version, commit the release changes, and push them. Use when the user asks to bump or increment the version, including a patch, minor, major, or explicit version bump.
---

# Bump version

A request to bump the version authorizes this complete workflow: clear local `dist`, increment the version, commit, and push. Proceed without another confirmation unless a concrete ambiguity prevents choosing the repository, release contents, or push destination. Creating or editing this skill alone does not execute a release.

## Workflow

1. Resolve the current Git repository root and inspect its working tree, branch, upstream, version sources, and release workflow. Fetch the relevant remote refs and tags before selecting a version. Use the existing upstream destination, or `origin` and the current branch when no upstream is configured. Resolve a missing destination or detached HEAD before making changes.
2. Use the version explicitly requested, or increment the requested semantic version component. Default to a **patch** bump when the user only says “bump version.” Determine the current version from the repository's actual release source; check remote tags to avoid collisions. Announce the old and new versions.
3. Clear only `<repository-root>/dist`, including hidden generated files. A missing folder is fine. Resolve the repository root first; never use a broad clean command. If `dist` is a symlink, remove the link itself without following it. Leave `dist` absent or empty at the end.
4. Update the repository's authoritative version and any coupled version metadata or lockfiles. Preserve environment overrides and existing versioning conventions. For tag-based releases, select the new tag now and create it on the final commit after validation. Do not rewrite historical examples or introduce a second versioning system.
5. Run appropriate existing checks before committing. Prefer checks that do not recreate `dist`; if a required build does recreate it, clear that generated folder again. Fix failures caused by the release changes. Stop on unresolved failures and report them without pushing.
6. Review and stage the version changes and the completed work being released in this session. Include intentional code, documentation, and asset changes; inspect untracked files before staging. Preserve unrelated local work and do not silently include it. Commit with a message such as `chore: release vX.Y.Z`. Do not amend an existing commit unless requested.
7. Push the commit to the chosen branch and, when the repository releases from tags, create and push the new version tag on that exact commit. Prefer one atomic push of the explicit branch and new tag when supported; otherwise push the branch successfully before the tag. Do not push all tags or force-push. If a push fails, inspect remote state before retrying; stop if recovery would require rewriting shared history or changing the release version/scope.
8. Verify that the remote branch and any release tag point to the intended commit. Report the version, commit, pushed branch/tag, validation result, and that `dist` was cleared. Do not claim the release workflow succeeded merely because a push succeeded.

## Mac Mobile Dev Helper conventions

Apply these details only to `DawidMoza/mac-mobile-dev-helper`; recheck the files in case its release conventions have changed.

- Published versions are semantic Git tags named `vX.Y.Z`. Use the latest release tag as the version baseline, rather than the fallback version in `scripts/build-app.sh`.
- `.github/workflows/release.yml` runs on pushed `v*` tags and creates the GitHub Release. Pushing the release tag is part of this repository's version-bump workflow.
- Update the fallback `VERSION` in `scripts/build-app.sh` to the selected `X.Y.Z`, retaining the environment override and `v`-prefix stripping. This keeps direct local builds aligned with the release. Installation and self-update already pass the tag through `VERSION`.
- Keep the existing `BUNDLE_VERSION` convention unless the user requests a build-number change.
- Run `swift test` and `git diff --check`. Do not run `scripts/build-app.sh` just for this workflow, because it repopulates `dist`.
