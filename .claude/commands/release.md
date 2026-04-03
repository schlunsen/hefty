Release a new version of hefty.

Usage: /release <version>
Example: /release 0.3.0

Steps to perform:
1. Verify we are on the `main` branch and it is clean (no uncommitted changes)
2. Run `cargo test` to make sure all tests pass
3. Update the version in `Cargo.toml` to the provided version (e.g. `$ARGUMENTS`)
4. Run `cargo build --release` to update `Cargo.lock` with the new version
5. Commit the version bump: `git add Cargo.toml Cargo.lock && git commit -m "Bump version to $ARGUMENTS"`
6. Push to main: `git push`
7. Create and push the git tag: `git tag v$ARGUMENTS && git push origin v$ARGUMENTS`
8. Monitor the GitHub Actions release workflow until it completes
9. Verify the release was created on GitHub
10. Report the release URL to the user
