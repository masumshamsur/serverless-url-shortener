# Documentation Index

For the project overview, architecture, and status, see the
[root README](../README.md) — this folder is the deep-dive layer beneath
it: a step-by-step build log, not a landing page.

This folder exists for two purposes:

1. **Future reference** — if you come back to this project in six months,
   these docs explain *why* each piece exists, not just what it is.
2. **Interview prep** — each step includes the new concepts it introduced,
   explained in a what / why / how / where-it-connects / what-if-missing
   format, so you can review without re-reading Terraform code.

## Structure

| File | Contents |
|---|---|
| [`architecture.md`](./architecture.md) | **Start here for the big picture** — objective, resource inventory, and diagrams showing how everything connects (runtime request flow + CI/CD deploy flow) |
| [`phase-1-infrastructure.md`](./phase-1-infrastructure.md) | Terraform: provider, DynamoDB, IAM, Lambda, API Gateway, outputs |
| [`phase-2-application-code.md`](./phase-2-application-code.md) | Python Lambda logic: short-code generation, DynamoDB access, validation, error handling |
| [`phase-3-cicd.md`](./phase-3-cicd.md) | Git, GitHub, OIDC, GitHub Actions deploy pipeline |
| [`concepts-glossary.md`](./concepts-glossary.md) | Every new concept introduced across all phases, in one flat reference list |
| [`troubleshooting.md`](./troubleshooting.md) | Every real issue hit, how it was diagnosed, root cause, and the fix |
| [`interview-prep.md`](./interview-prep.md) | Likely interview questions and answers, grounded in this project, organized by topic |
