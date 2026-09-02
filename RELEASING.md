# Releasing

Release only from a clean `main` branch after all required checks pass.

1. Record UTC and local time with `date`; use the verified local calendar date
   for `CHANGELOG.md`, and never derive it from chat, memory, or a previous
   build.
2. Run the complete offline suite and the skill validator on an Intel Mac.
3. Run `gh skill publish --dry-run`. Treat every error and warning as a release
   blocker.
4. Verify that the active `Protect release tags` ruleset targets `v*`, rejects
   tag updates and deletions, allows new tag creation, and has no bypass actors.
5. Review the repository for credentials, private host evidence, absolute user
   paths, downloaded archives, and unpinned workflow actions.
6. Update `CHANGELOG.md` with the verified date and merge the release change
   through the protected `main` branch after all required checks pass.
7. Create an SSH-signed annotated release tag on the exact merged commit. Push
   it once, then verify the tag locally and verify the tagged commit through the
   GitHub API. Never rewrite or delete a published release tag; publish a new
   patch version to correct a release.
8. Run `gh skill publish --tag <tag>` against the existing signed tag. Verify
   that the GitHub release is neither a draft nor a prerelease and targets the
   exact tagged commit. Do not attach locally collected inventory, package
   archives, or credentials.
9. Install the exact release into a clean temporary directory:

   ```sh
   release_tag=vX.Y.Z
   release_dir=$(mktemp -d)
   gh skill install \
     ragtimelab/intel-homebrew-bottle-migrator \
     intel-homebrew-bottle-migrator \
     --pin "$release_tag" \
     --dir "$release_dir"
   ```

   Rerun validation and the offline suite, then compare its files with the
   tagged tree after normalizing only publisher-injected `metadata.github-*`
   frontmatter.
10. Check Skills CLI discovery with `npx skills add <owner>/<repo> --list`.
    Send one real, project-scoped, telemetry-enabled install only for initial
    skills.sh registration; do not repeat installs to manipulate indexing or
    install counts.
11. Verify the skills.sh download snapshot, exact-owner search result, rendered
    detail page, and badge. If indexing remains unavailable after a bounded
    recheck, search for duplicates and file one privacy-safe upstream issue
    instead of retrying installs.

Never weaken branch rules, action pinning, signature requirements, or the
binary-only runtime policy to complete a release.
