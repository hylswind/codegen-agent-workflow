Implement the application described in SPEC.md, following CONTRACT.md exactly.

1. Read SPEC.md and CONTRACT.md completely before writing anything.
2. Choose the language and runtime that fit the spec best. If the spec names a language, use it. Use only Amazon Linux 2023 packages listed or reachable as described in CONTRACT.md.
3. Write the complete, working application in this directory: source code, tests, the build and test scripts, a README.md, and app.yaml exactly as CONTRACT.md specifies.
4. `build` must leave everything the app needs at run time in ./dist, and `exec` must start the app from there. The healthcheck path must return HTTP 200 once the app is ready. Listen on 0.0.0.0.
5. Build and test locally as far as this machine allows and fix problems until they pass. The pipeline will repeat the build and tests in a clean Amazon Linux 2023 container.
6. Finish with a short summary: what you built, the language and packages you chose, and any spec items you could not implement and why.
