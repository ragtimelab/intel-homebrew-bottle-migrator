# Security Policy

## Supported versions

Security fixes are provided for the latest published release. Users should install a signed release tag rather than the moving `main` branch.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/ragtimelab/intel-homebrew-bottle-migrator/security/advisories/new) for this repository. Do not open a public issue for a suspected vulnerability and do not include credentials, private inventory reports, home-directory paths, or package-manager logs containing personal data in a public report.

Include the affected release, a minimal reproduction, expected and observed behavior, impact, and any evidence needed to distinguish an audit-only issue from a package-state mutation issue. Maintainers will acknowledge a report within three business days, provide an initial status update within seven business days, and aim to remediate confirmed issues within 90 days. Critical issues are prioritized for the earliest safe release. Timelines may change with complexity and coordinated-disclosure needs; the reporter will receive an updated estimate when that happens.

Maintainers investigate reports privately, coordinate fixes and disclosure with the reporter, and publish a GitHub Security Advisory when appropriate. Public disclosure should wait until a fix or documented mitigation is available.

## Security boundaries

The project treats shell injection, path traversal, symlink races, unsafe archive handling, forged plan data, inventory drift, source-build fallback, cross-prefix linkage, secret leakage, and unauthorized package mutation as security-sensitive defects.

The project never requests or stores an administrator password. A legitimate workflow may ask macOS to display its normal authentication prompt immediately before an explicitly approved MacPorts operation.
