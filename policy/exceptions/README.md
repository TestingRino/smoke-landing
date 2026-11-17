# Gate exceptions

Exceptions live here, in the control repo, so that an app repo **cannot waive its own findings**.
The gate deletes `.gitleaksignore`, `.semgrepignore` and `.trivyignore` from the scanned checkout
and runs semgrep with `--disable-nosem`.

Make a folder named exactly after the repo and add any of these files:

| File | Format | Effect |
|---|---|---|
| `<repo>/gitleaksignore` | gitleaks fingerprints, one per line (from the gate report artifact) | suppress specific secret findings |
| `<repo>/trivyignore` | CVE / misconfig IDs, one per line, `#` comments allowed | suppress vulns/misconfigs |
| `<repo>/semgrep-exclude-rules.txt` | semgrep rule IDs, one per line | skip those rules |

Each exception should have a comment explaining why, and get reviewed in a PR.

Known gap: gitleaks still honours inline `gitleaks:allow` comments in the source code. Reviewers should look for them.
