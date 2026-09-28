# Troubleshooting Log

Every real issue hit during this build, in the order encountered: the
symptom as it actually appeared, the diagnostic steps taken (not just the
answer), the root cause, and the fix. Kept separate from the phase docs
because debugging methodology is its own interview-relevant skill, distinct
from "what did we build."

---

## 1. OIDC `AssumeRoleWithWebIdentity` — "Not authorized"

**Phase:** 3, Step 4 (writing `deploy.yml`)

**Symptom:**
```
Assuming role with OIDC
Assuming role with OIDC
... (repeated ~12 times, ~2 minutes of internal retries)
Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```
The `validate` job passed every time; only `deploy`'s
`Configure AWS credentials via OIDC` step failed — consistently, on two
separate runs.

**Diagnostic steps taken (in order):**
1. Re-verified the trust policy already applied to the role via
   `aws iam get-role --role-name url-shortener-github-actions-deploy
   --query "Role.AssumeRolePolicyDocument"` — looked correct on paper (both
   `aud` and `sub` conditions present, values appeared right).
2. Considered IAM eventual-consistency (a freshly created/updated IAM
   role/policy can take a short time to propagate). Tested by reruning the
   failed job with `gh run rerun --failed <run-id>` after waiting — **same
   failure**, ruling this out as the cause.
3. Since two independent runs hit the identical error at the identical
   step, concluded this was a **persistent config mismatch**, not a
   transient/propagation issue — the trust policy's condition wasn't
   matching the token GitHub actually issues.
4. Added a **temporary debug step** to `deploy.yml`, before
   `configure-aws-credentials`, that requests GitHub's real OIDC token and
   decodes its JWT payload (the middle base64 segment) to print the actual
   claims:
   ```yaml
   - name: Debug - decode OIDC token claims
     run: |
       IDTOKEN=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
         "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r '.value')
       echo "$IDTOKEN" | cut -d '.' -f2 | base64 -d 2>/dev/null | jq .
   ```
   Safe to do: JWT *claims* (unlike raw secrets) aren't automatically
   masked in Actions logs, and none of the printed fields are sensitive —
   `sub`, `aud`, `repository`, etc. are effectively public metadata about
   the run.
5. Pushed, then read the decoded claims directly from the log:
   ```
   "aud": "sts.amazonaws.com",
   "sub": "repo:masumshamsur@128269966/serverless-url-shortener@1388368455:ref:refs/heads/main",
   ```
   Compared byte-for-byte against the trust policy's expected value:
   ```
   "repo:masumshamsur/serverless-url-shortener:ref:refs/heads/main"
   ```
   **Mismatch found:** the real token embeds numeric owner/repo IDs
   alongside the names (`masumshamsur@128269966`,
   `serverless-url-shortener@1388368455`); the trust policy was written
   with the plain-name-only format.

**Root cause:** GitHub's OIDC token issues an **ID-qualified** `sub` claim
(`owner@ownerId/repo@repoId`), not just plain names. The trust policy
condition had been written using the plain-name format commonly shown in
older docs/examples, which no longer matches what GitHub actually sends.

**Fix:** update the trust policy's `sub` condition value to the exact
ID-qualified string:
```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:masumshamsur@128269966/serverless-url-shortener@1388368455:ref:refs/heads/main"]
}
```
then `terraform apply`, then push again to trigger a real run.

**Status:** ✅ resolved and confirmed. After applying the fix and pushing,
run `36368491904` completed with both jobs green — `Configure AWS
credentials via OIDC` succeeded, and both `Zip and deploy` steps ran
`aws lambda update-function-code` successfully. See
[`phase-3-cicd.md`](./phase-3-cicd.md) Step 4 for full details.

**Lesson / prevention:** when a federated-identity trust condition fails
with "Not authorized" (as opposed to an "Invalid identity token" error,
which would point to the IdP registration itself), don't assume the
documented claim format is what's actually being issued — **decode the
real token and compare claims directly**, rather than guessing from
memory or examples. This is also a more general lesson about OIDC/JWT
debugging that applies well beyond AWS+GitHub: the token is directly
inspectable (it's just base64, not encrypted), so inspect it before
theorizing.

---

## 2. Phantom Lambda redeploy from a stray `__pycache__`

**Phase:** 3, Step 2 (before writing `deploy.yml`)

**Symptom:** `terraform plan` showed `aws_lambda_function.create_link`
would be updated in-place (`source_code_hash` changing), despite no edits
to `app.py`.

**Diagnostic steps:** recognized that `archive_file` zips the literal
filesystem contents of `source_dir` at apply time, with no awareness of
`.gitignore`. Correlated the timing: an earlier local
`python3 -c "from app import ..."` test had regenerated
`src/create_link/__pycache__/app.cpython-314.pyc`, which had been silently
included in the previously-deployed zip. That stray file had since been
deleted (Phase 3 Step 1's cleanup before the first git commit), so the zip
content — and its hash — legitimately changed.

**Root cause:** `archive_file` has no concept of "ignored" files; it
packages whatever is physically present in the source directory.

**Fix:** added `excludes = ["__pycache__"]` to both `archive_file` blocks
in `lambda.tf`, so future local test runs (which regenerate
`__pycache__`) can never affect the deployed package again.

**Lesson / prevention:** for any Terraform data source that reads the
filesystem directly (`archive_file`, `local_file`, etc.), remember it does
**not** respect `.gitignore` — git and Terraform have separate, unrelated
views of "what's in this directory."

---

## 3. `gh` CLI assumed installed, wasn't

**Phase:** 3, Step 1

**Symptom:** `gh repo create ...` → `command not found: gh`, despite the
user believing it was already set up.

**Diagnostic steps:** `which gh` and a Homebrew formula check both
confirmed it genuinely wasn't installed or on `PATH`.

**Fix:** `brew install gh`, then `gh auth login` (browser-based device
flow), confirmed with `gh auth status`.

**Lesson:** verify tooling assumptions with a real command
(`which <tool>`) rather than trusting recollection, especially before
depending on it for the next several steps.

---

## 4. Terminal bracketed-paste artifact breaking a pasted command

**Phase:** 2, Step 4

**Symptom:**
```
zsh: bad pattern: ^[[200~aws
```
when pasting a multi-line `aws lambda invoke` command.

**Root cause:** the terminal's "bracketed paste mode" (which is supposed
to wrap pasted text in invisible marker sequences so the shell can tell
paste apart from typing) wasn't being fully interpreted, so the raw
escape codes leaked into the command line as literal text.

**Fix:** simply re-ran the same command; it pasted cleanly the second
time. Not a code or config issue — a one-off terminal/paste glitch.

**Lesson:** an escape-code-looking prefix in a shell error
(`^[[` sequences) points to a terminal input artifact, not a real syntax
problem with the command itself — don't chase phantom bugs in a command
that's actually fine.

---

## 5. Literal placeholder pasted into a command

**Phase:** 1, Step 5

**Symptom:** `zsh: no such file or directory: api-id` after running a curl
command that still contained the literal placeholder text `<api-id>`.

**Root cause:** copy-pasted an example command without substituting the
placeholder with the real value (zsh interpreted `<api-id>` as an input
redirect from a file named `api-id`).

**Fix:** substitute the real endpoint (`fpzqe4wtn9...`) before running.

**Lesson:** angle-bracket placeholders (`<like-this>`) in example commands
are never meant to be typed literally — always a stand-in for a real value
from a previous step's output.

---

## 6. `terraform output` showing "No outputs found" once

**Phase:** 1, Step 6

**Symptom:** `terraform apply` reported `0 added, 0 changed, 0 destroyed`
with no `Outputs:` section, and a subsequent `terraform output` warned
"No outputs found," even though `outputs.tf` had just been created.

**Root cause (most likely):** a timing issue — the file may not have been
fully saved by the editor at the moment `apply` ran. Re-running `apply`
immediately after picked up the outputs correctly.

**Fix:** simply re-ran `terraform apply`; outputs appeared correctly.

**Lesson:** if a Terraform command's behavior doesn't match what the
current file content implies, re-run before assuming a deeper bug —
editor save timing is a mundane but real source of confusing one-off
results.
