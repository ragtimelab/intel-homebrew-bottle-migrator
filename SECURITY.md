# Security Policy

## Supported versions

Security fixes are provided for the latest published minor release. Users should install a signed release tag rather than the moving `main` branch.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository. Do not open a public issue for a suspected vulnerability and do not include credentials, private inventory reports, home-directory paths, or package-manager logs containing personal data in a public report.

Include the affected release, a minimal reproduction, expected and observed behavior, impact, and any evidence needed to distinguish an audit-only issue from a package-state mutation issue. Maintainers will acknowledge the report, investigate it privately, coordinate a fix and disclosure, and publish a GitHub Security Advisory when appropriate.

## Security boundaries

The project treats shell injection, path traversal, symlink races, unsafe archive handling, forged plan data, inventory drift, source-build fallback, cross-prefix linkage, secret leakage, and unauthorized package mutation as security-sensitive defects.

The project never requests or stores an administrator password. A legitimate workflow may ask macOS to display its normal authentication prompt immediately before an explicitly approved MacPorts operation.
