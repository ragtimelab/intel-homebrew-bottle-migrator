# Releasing

Release only from a clean `main` branch after all required checks pass.

1. Run the offline test suite and the skill validator on an Intel Mac.
2. Review the repository for credentials, private host evidence, absolute user
   paths, downloaded archives, and unpinned workflow actions.
3. Update `CHANGELOG.md` using a timestamp verified with `date`.
4. Create an SSH-signed release commit and an SSH-signed annotated tag.
5. Push the commit and tag, then verify GitHub displays both signatures as
   verified.
6. Create GitHub release notes from the signed tag. Do not attach locally
   collected inventory, package archives, or credentials.
7. Install the released skill by immutable tag into a clean temporary harness,
   rerun validation, and compare the installed tree with the tagged tree.

Never weaken branch rules, action pinning, signature requirements, or the
binary-only runtime policy to complete a release.
