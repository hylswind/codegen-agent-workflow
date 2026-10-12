Bring the application in this directory up to date.

This directory is a checkout of the repository and commit named in .pipeline/base.json. SPEC.md is the specification as of that commit and must not be modified. CONTRACT.md is the packaging contract the pipeline enforces.

1. Read SPEC.md, CONTRACT.md and the code completely before changing anything.
2. List what SPEC.md requires that the code lacks or does differently, and fix it.
3. Update dependencies and the toolchain to current versions where the tests still pass: the language version, modules or packages, and the Amazon Linux 2023 package names in app.yaml.
4. Fix deprecated usage and known security issues you find.
5. Keep behaviour and structure. Change only what the steps above need; do not rewrite working parts. Keep app.yaml valid per CONTRACT.md.
6. Build and test locally as far as this machine allows and fix problems until they pass. The pipeline will repeat the build and tests in a clean Amazon Linux 2023 container.
7. Finish with a summary listing each change and its reason: a SPEC requirement, a dependency update, or a fix.
