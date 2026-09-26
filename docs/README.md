# Serverless URL Shortener — Lab Journal

This folder is a running record of this project, built step by step, in the
order it was actually built. It exists for two purposes:

1. **Future reference** — if you come back to this project in six months,
   these docs explain *why* each piece exists, not just what it is.
2. **Interview prep** — each step includes the new concepts it introduced,
   explained in a what / why / how / where-it-connects / what-if-missing
   format, so you can review without re-reading Terraform code.

## Structure

| File | Contents |
|---|---|
| [`phase-1-infrastructure.md`](./phase-1-infrastructure.md) | Terraform: provider, DynamoDB, IAM, Lambda, API Gateway, outputs |
| [`phase-2-application-code.md`](./phase-2-application-code.md) | Python Lambda logic: short-code generation, DynamoDB access, validation, error handling |
| [`phase-3-cicd.md`](./phase-3-cicd.md) | Git, GitHub, OIDC, GitHub Actions deploy pipeline |
| [`concepts-glossary.md`](./concepts-glossary.md) | Every new concept introduced across all phases, in one flat reference list |

## Project summary

A minimal serverless app with two routes behind an API Gateway HTTP API:

- `POST /links` — accepts a long URL, validates it, generates a short code,
  stores `{shortCode, longUrl, clicks, createdAt}` in DynamoDB.
- `GET /{code}` — looks up the code, atomically increments a click counter,
  and returns a 302 redirect to the original URL (404 if the code doesn't exist).

Deliberately excluded: authentication (Cognito), a hosted frontend
(S3/CloudFront), email (SES). Public API, tested with curl/Postman.

**Services used:** API Gateway (HTTP API), Lambda (Python, 2 functions),
DynamoDB (1 table), IAM (1 shared execution role), CloudWatch (logs +
optionally 1 alarm), GitHub Actions with OIDC (no stored AWS keys).

**Account / region used in this lab:** account `842190336606`, region
`us-east-1`.
