# Serverless URL Shortener

![AWS](https://img.shields.io/badge/AWS-Lambda%20%7C%20API%20Gateway%20%7C%20DynamoDB-orange)
![Terraform](https://img.shields.io/badge/IaC-Terraform-844FBA)
![Python](https://img.shields.io/badge/Python-3.13-blue)
![CI/CD](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions%20%2B%20OIDC-2088FF)

A minimal, fully serverless URL shortener on AWS — built to demonstrate
production-grade infrastructure and deployment practices on a
deliberately small feature set: `POST` a long URL, get a short code back;
`GET` the short code, get redirected, with an atomic click counter.

**100% Infrastructure as Code** (Terraform, written from scratch — no
console-created or imported resources) and **100% keyless CI/CD**
(GitHub Actions authenticated via OIDC federation — no AWS access keys
stored anywhere).

## Architecture

```mermaid
flowchart LR
    Client(["Client"]) -->|"POST /links"| APIGW["API Gateway<br/>HTTP API"]
    Client -->|"GET /{code}"| APIGW

    APIGW -->|AWS_PROXY| CreateLink["Lambda<br/>create_link"]
    APIGW -->|AWS_PROXY| Redirect["Lambda<br/>redirect"]

    CreateLink -->|"conditional PutItem"| DDB[("DynamoDB<br/>Links table")]
    Redirect -->|"atomic UpdateItem<br/>(ADD clicks)"| DDB

    Redirect -->|"302 redirect"| Client
    CreateLink -->|"201 + shortCode"| Client
```

```mermaid
flowchart LR
    Dev(["git push main"]) --> GA["GitHub Actions"]
    GA -->|"validate (no AWS creds)"| TF["terraform validate/fmt"]
    GA -->|"OIDC token"| STS["AWS STS<br/>AssumeRoleWithWebIdentity"]
    STS -->|"~1hr temp credentials"| GA
    GA -->|"UpdateFunctionCode only"| Lambda["The 2 project<br/>Lambda functions"]
```

Full diagrams with request/deploy walkthroughs:
[`docs/architecture.md`](./docs/architecture.md)

## What this demonstrates

- **Infrastructure as Code from scratch** — every resource defined in
  Terraform and applied from an empty account state, not imported from
  console-created resources
- **Least-privilege IAM, applied concretely, twice** — a Lambda execution
  role scoped to 3 DynamoDB actions on 1 table; a CI deploy role scoped
  to exactly `lambda:UpdateFunctionCode` on exactly 2 function ARNs
- **Keyless CI/CD via OIDC federation** — no long-lived AWS credentials
  stored in GitHub, ever; short-lived per-run credentials via
  `AssumeRoleWithWebIdentity`
- **Correct concurrency handling in DynamoDB** — atomic click-counter
  increments (`UpdateItem` `ADD`, not read-modify-write) and
  collision-guarded short-code generation (conditional `PutItem`)
- **Real debugging, documented** — including a full investigation into a
  GitHub OIDC token-format mismatch, root-caused by decoding the actual
  JWT rather than trusting documentation
  ([full writeup](./docs/troubleshooting.md))
- **Deliberately scoped** — no Cognito/auth, no frontend hosting, no
  email; three services doing one job each, not a kitchen sink

## Tech stack

| Layer | Choice |
|---|---|
| Compute | AWS Lambda (Python 3.13, arm64/Graviton2) |
| API | Amazon API Gateway (HTTP API) |
| Data | Amazon DynamoDB (on-demand) |
| IaC | Terraform |
| CI/CD | GitHub Actions + OIDC federation |
| Observability | CloudWatch Logs (explicit retention) |

## Try it

```bash
# Create a short link
curl -s -X POST https://fpzqe4wtn9.execute-api.us-east-1.amazonaws.com/links \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com/masumshamsur"}'
# → {"shortCode": "...", "longUrl": "...", "createdAt": ...}

# Follow it
curl -iL https://fpzqe4wtn9.execute-api.us-east-1.amazonaws.com/<shortCode>
```

> **Note:** this is a personal lab project — the live endpoint above may
> be torn down at some point to avoid ongoing AWS costs. The full build,
> including every command run and its real output, is preserved in
> [`docs/`](./docs/).

## Repo structure

```
terraform/    # All infrastructure, written from scratch
src/          # Lambda application code (2 functions)
.github/      # CI/CD pipeline (validate + OIDC-authenticated deploy)
docs/         # Full build log, architecture, troubleshooting, concepts
```

## Documentation

This project was built and documented as a structured learning exercise,
in three phases — infrastructure, application code, CI/CD — each with
full command history and results, not just final code:

- [`docs/architecture.md`](./docs/architecture.md) — the big picture: objective, resource inventory, diagrams
- [`docs/phase-1-infrastructure.md`](./docs/phase-1-infrastructure.md) · [`phase-2-application-code.md`](./docs/phase-2-application-code.md) · [`phase-3-cicd.md`](./docs/phase-3-cicd.md) — full build log
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) — real issues hit, root cause, and fix
- [`docs/concepts-glossary.md`](./docs/concepts-glossary.md) — every concept covered, in one reference
- [`docs/interview-prep.md`](./docs/interview-prep.md) — Q&A grounded in this project
