# Phase 3 — CI/CD (GitHub Actions + OIDC)

Goal of this phase: push to `main` and have GitHub Actions validate the
Terraform config (no AWS credentials involved) and deploy the Lambda code via
OIDC-assumed, narrowly-scoped credentials — no long-lived AWS keys stored in
GitHub.

Not started yet. Will cover, at minimum:

- Initializing git, `.gitignore` for Terraform state/secrets, pushing to a
  new GitHub repo
- The OIDC identity provider trust relationship between GitHub Actions and AWS
- A narrowly-scoped IAM role (only `UpdateFunctionCode` on this project's two
  specific Lambda functions — nothing else)
- `deploy.yml`: a validate job (no AWS creds) and a deploy job (OIDC-assumed
  creds), triggered on push to `main`
- End-to-end test: push a small code change, watch it deploy automatically
