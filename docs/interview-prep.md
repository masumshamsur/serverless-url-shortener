# Interview Prep — Q&A

Every question here is answerable directly from this project — no
memorized theory, just "what did you actually build and why." Organized
by topic, roughly in the order the project was built. A few are marked
**[STAR]** — strong candidates for "tell me about a time..." behavioral
questions, since they involve a real problem, a real investigation, and a
real fix.

Cross-references point back to [`concepts-glossary.md`](./concepts-glossary.md)
for the compressed version of each concept, and the phase docs for full
context.

---

## Resume / LinkedIn bullet points

**Full version (resume "Projects" section, 3-4 bullets):**

> **Serverless URL Shortener** — Terraform, AWS Lambda, API Gateway, DynamoDB, GitHub Actions
> *[github.com/masumshamsur/serverless-url-shortener]*
> - Architected and provisioned a serverless AWS application (API Gateway, Lambda, DynamoDB, IAM, CloudWatch) entirely from scratch in Terraform, with zero console-created or imported resources
> - Designed least-privilege IAM policies scoped to individual API actions and specific resource ARNs — a CI/CD deploy role limited to a single Lambda action on exactly 2 function resources, containing the blast radius of a compromised pipeline run
> - Built a keyless CI/CD pipeline (GitHub Actions + OIDC federation) that eliminates all long-lived AWS credentials, using short-lived per-run STS credentials scoped by repository and branch
> - Implemented correct DynamoDB concurrency handling — atomic counter increments and collision-guarded conditional writes — avoiding lost-update races under concurrent requests

**Compact version (one-page resume, single line):**

> Built and deployed a serverless URL shortener on AWS (Lambda, API Gateway, DynamoDB) with Terraform IaC and a keyless GitHub Actions CI/CD pipeline authenticated via OIDC — no stored AWS credentials.

**LinkedIn "Projects" section (slightly more narrative):**

> A small serverless app (AWS Lambda, API Gateway, DynamoDB) built to practice production-grade infrastructure and deployment practices on a deliberately minimal feature set. Every resource is provisioned from scratch in Terraform, and the CI/CD pipeline deploys via GitHub Actions using OIDC federation — meaning no AWS access keys are ever stored in GitHub. Along the way I debugged a real GitHub OIDC token-format mismatch by decoding the actual JWT rather than trusting documentation — full write-up in the repo. [link]

Pick the version that fits the space you have — the full version is best
for a dedicated "Projects" section, the compact one for a skills-dense
one-pager, and the LinkedIn version leans slightly more narrative since
that platform rewards a bit more context than a resume does.

---

## Project overview (the 60-second version)

**Q: Walk me through this project.**
A: A serverless URL shortener on AWS — API Gateway HTTP API in front of
two Lambda functions (Python), backed by one DynamoDB table. `POST
/links` validates a submitted URL, generates a random 7-character short
code, and writes it to DynamoDB with a uniqueness guard. `GET /{code}`
atomically increments a click counter and returns a 302 redirect, or a
404 if the code doesn't exist. Everything is provisioned from scratch in
Terraform — no console-created resources, no imports — and deployed via
GitHub Actions using OIDC federation, so there are no long-lived AWS
credentials stored anywhere in GitHub. I built it in three deliberately
separate phases: infrastructure first (with placeholder Lambda code, to
prove the wiring before writing logic), then the real application code,
then CI/CD.

**Q: Why two Lambda functions instead of one with internal routing?**
A: Separation of concerns and blast radius. `create_link` and `redirect`
have very different traffic shapes — reads (`redirect`) vastly outnumber
writes (`create_link`) in any real short-link service — and separating
them gives independent scaling, independent CloudWatch log groups and
error metrics, and means a bug in one path can't break the other. The
trade-off is more Terraform resources and a shared IAM role that's
slightly broader than strictly necessary (it has `PutItem`, `GetItem`,
*and* `UpdateItem`, even though each function only uses a subset) — one
role per function would be tighter, but was a reasonable trade for a
project this size.

---

## Terraform / Infrastructure as Code

**Q: What's the difference between Terraform state and Terraform code?**
A: Code (`.tf` files) is the desired configuration. State
(`terraform.tfstate`) is Terraform's record of what it actually created
last time — mapping each resource block to a real AWS object's ID/ARN and
attributes. `terraform plan` diffs desired (code) against actual (state,
refreshed live from AWS) to compute what needs to change. Without state,
Terraform has no memory of what it made, and can't update or destroy
resources safely.

**Q: Why should `.tfstate` never be committed to git, but
`.terraform.lock.hcl` should?**
A: State can contain sensitive resource attributes, and it's a
single-writer file — two people (or a person and CI) applying against the
same committed state file would immediately conflict. The lock file is
different: it's small, human-readable, and pins the exact provider
version and checksums, so `terraform init` resolves identically whether
run locally or in CI — the whole point of committing it is to *prevent*
drift, not enable it. (See [`troubleshooting.md`](./troubleshooting.md) —
this exact distinction shaped the `.gitignore`.)

**Q: When would you use a Terraform `data` source instead of a
`resource`?**
A: When something already exists and you need to reference its
attributes, not manage its lifecycle. In this project: the GitHub Actions
OIDC identity provider already existed in the AWS account (created by a
prior project) — AWS IAM only permits one per unique provider URL per
account, so creating a second `resource` block for it would error.
Instead, `data "aws_iam_openid_connect_provider"` does a read-only lookup
and I reference its `.arn` in the new role's trust policy.

**Q: How does Terraform know when to redeploy Lambda code?**
A: Via `source_code_hash`, set to the deployment zip's
`output_base64sha256` (computed by the `archive_file` data source).
Without it, Terraform only notices a redeploy is needed when a resource
*argument* changes (memory, timeout, etc.) — it can't otherwise detect
that the zip's *bytes* changed.

**Q: What's a subtle gotcha with `archive_file` you actually hit?**
A: It zips the literal filesystem contents of the source directory —
completely independent of `.gitignore`. An earlier local Python test had
regenerated a `__pycache__/*.pyc` file, which silently got bundled into
the deployed Lambda package. `terraform plan` later showed an unexplained
`source_code_hash` change with no code edits — the fix was adding
`excludes = ["__pycache__"]` to the `archive_file` block, not just
deleting the stray file once. (Full write-up:
[`troubleshooting.md`](./troubleshooting.md) #2.)

---

## DynamoDB

**Q: Why DynamoDB over RDS/a relational database here?**
A: Access pattern is a single point lookup by exact key (`GetItem` on
`shortCode`) with no relational joins, no complex queries, and highly
bursty/unpredictable traffic. DynamoDB's on-demand billing and
effectively unlimited horizontal scaling fit that shape better than
managing a relational instance's capacity for a workload with no
inherent relational structure.

**Q: How did you choose the partition key?**
A: `shortCode`, because it's the field every read pattern in this service
filters on — DynamoDB hashes the partition key to route to a physical
partition, so `GetItem` on it is an O(1) lookup, exactly matching the hot
path (`GET /{code}`). No sort key, because each short code maps to
exactly one item — there's no need for a range of items under one
partition key.

**Q: On-demand vs. provisioned billing — how did you decide?**
A: On-demand (`PAY_PER_REQUEST`), because traffic for a lab/small service
is unpredictable and likely near-zero most of the time — provisioned
capacity would mean paying for idle throughput. On-demand costs more per
request at *sustained high* volume, so a production service with
predictable steady traffic might switch to provisioned (or
provisioned-with-auto-scaling) once that traffic pattern is established.

**Q: DynamoDB is described as "schemaless" — what does that actually
mean, and what's still required?**
A: Only attributes used in a key (partition key, sort key, or a GSI/LSI
key) are declared at the table level. Every other attribute (`longUrl`,
`clicks`, `createdAt` here) is freeform — written per-item with no
table-level schema, and no `ALTER TABLE`-equivalent needed to add new
fields later. What's still required: key attribute *types* are
constrained to `S` (string), `N` (number), or `B` (binary).

**Q: How do you increment a counter safely under concurrent writes?**
A: Not with a read-modify-write (`GetItem` → add 1 in application code →
`PutItem`) — that has a lost-update race: two concurrent requests can
both read `clicks: 5`, both compute `6`, and one increment vanishes.
Instead, `UpdateItem` with `UpdateExpression: "ADD clicks :incr"`
performs the increment *inside* DynamoDB atomically — no read-modify-write
round trip, no application-level locking, and concurrent requests each
get their own atomic `+1` applied in sequence.

**Q: How did you avoid a second round trip to also fetch the target URL
during redirect?**
A: `ReturnValues="ALL_NEW"` on the same `UpdateItem` call returns the
complete updated item — including `longUrl` — alongside the increment. So
the redirect handler makes exactly one DynamoDB call total: increment and
read in one atomic operation. This also avoids a race where a separate
`GetItem` could observe the item being deleted between the two calls.

**Q: How do you prevent overwriting an existing short code on collision,
given codes are randomly generated?**
A: A conditional write:
`ConditionExpression="attribute_not_exists(shortCode)"` on `PutItem`.
DynamoDB fails the write atomically (raising
`ConditionalCheckFailedException`) if that key already exists, rather
than silently overwriting someone else's link. The handler catches that
specific exception and retries with a freshly generated code, bounded to
a small number of attempts.

**Q: What's the "birthday paradox" have to do with your short-code
length choice?**
A: With a 62-character alphabet at length 7, there are `62^7 ≈ 3.5
trillion` possible codes — but the relevant collision math isn't the
total space size, it's that you'd expect a 50% chance of *any* collision
after roughly `√(62^7) ≈ 1.87 million` generated codes, not after 3.5
trillion. Far more than a lab needs, but "very unlikely" isn't
"impossible" — which is why correctness still depends on the conditional
write, not on the odds being favorable.

**Q: `ConditionExpression="attribute_exists(...)"` shows up in your
`redirect` handler too, for a different reason — what's it doing there?**
A: `UpdateItem`'s `ADD` action defaults to upsert semantics — without this
condition, hitting a nonexistent short code would silently *create* a
garbage item (`clicks: 1`, no `longUrl`) instead of failing. Requiring
`attribute_exists` turns "code not found" into the same
`ConditionalCheckFailedException` pattern used for collision detection,
caught and converted into a clean 404.

---

## IAM / Security

**Q: What's the difference between a trust policy and a permissions
policy on an IAM role?**
A: Trust policy (`assume_role_policy`) governs *who* can assume the role
— for a Lambda execution role, that's the Lambda service itself
(`lambda.amazonaws.com`); for the CI deploy role, it's GitHub's OIDC
provider, gated by conditions on the token's claims. Permissions
policies govern *what the role can do* once assumed. They're separate
because they fail differently: a broken trust policy means the
role/function can't even be assumed/started; a broken permissions policy
means it starts but fails on its first API call.

**Q: How did you apply least privilege in this project — give concrete
examples.**
A: Two places. (1) The Lambda execution role's DynamoDB policy is scoped
to exactly `PutItem`/`GetItem`/`UpdateItem` on one table's ARN — not
`AmazonDynamoDBFullAccess`, which would grant access to every table in the
account. (2) The CI deploy role's policy is scoped to exactly
`lambda:UpdateFunctionCode` on exactly the two project function ARNs —
not `InvokeFunction`, not config changes, not a wildcard resource — so
even a fully compromised CI run can only ever push code to these two
functions, nothing else in the account.

**Q: What's a resource-based policy, and where did you need one that
an identity-based (execution role) policy didn't cover?**
A: `aws_lambda_permission` — a policy attached to the Lambda function
itself (not the caller), granting `lambda:InvokeFunction` to
`apigateway.amazonaws.com`, scoped via `source_arn` to this specific API.
The Lambda execution role controls what the function can do once
*running*; it says nothing about who's allowed to *invoke* it in the
first place. Missing this resource-based permission is a very common
"everything looks wired correctly but I get a 500" trap with API Gateway
+ Lambda.

**Q: [STAR] Tell me about a security-relevant bug you found and fixed.**
A (situation): While debugging a persistent OIDC authentication failure
in CI (see the OIDC section below for the technical detail), I was
working directly with an IAM trust policy's `Condition` block — the exact
mechanism that scopes *which* GitHub repo/branch can assume an AWS role.
(Task): I needed to get this condition correct, because a too-broad
condition (or a careless wildcard) would let *any* GitHub Actions
workflow — including from repos I never intended — assume a role with
write access to my Lambda functions. (Action): rather than loosen the
condition to "make it work," I decoded the actual OIDC token GitHub was
issuing and found the real `sub` claim format was more specific than
what I'd written (ID-qualified, not just plain names) — so I tightened
my understanding of the exact expected value instead of weakening the
policy. (Result): the fix kept the trust policy exactly as narrowly
scoped as intended — one specific repo, one specific branch — while also
making it *more* correct going forward, since the ID-qualified format
survives a repo rename where the plain-name format wouldn't have.

---

## Lambda

**Q: Why are `boto3.resource(...)` and the DynamoDB `Table` object created
at module level, outside the handler function?**
A: Lambda reuses the same execution environment across "warm"
invocations — code outside `handler()` runs once per environment, not
once per request. Creating the SDK client there means it's reused across
invocations instead of rebuilt (and reconnected) on every single request,
which matters for both latency and resource usage under real traffic.

**Q: Why `python3.13` on `arm64` specifically?**
A: ARM (Graviton2) Lambda is generally ~20% cheaper and often faster than
x86 for typical workloads, with zero code changes required for pure
Python with no compiled native dependencies — free performance/cost win
with no downside for this workload.

**Q: How do you pass configuration (like a table name) into a Lambda
function without hardcoding it?**
A: Environment variables, set in Terraform from a resource attribute
(`TABLE_NAME = aws_dynamodb_table.links.name`) rather than a literal
string in the Python code. Keeps the value single-sourced in Terraform
and makes the same code portable across environments with zero code
changes.

**Q: What's the difference between Lambda's own invoke status and your
application's HTTP status code?**
A: `aws lambda invoke`'s `StatusCode: 200` only means "the handler ran to
completion without an unhandled exception" — it's independent of
whatever status code your handler's return value contains. Early in this
project, invoking the placeholder handler returned Lambda-level `200`
with an application-level `501` in the body — two separate layers that
are easy to conflate when debugging.

**Q: Explain the `AWS_PROXY` integration contract — what does your
Lambda actually receive and need to return?**
A: The entire raw HTTP request arrives as one JSON event (method, path,
headers, query string, body) with no field-by-field mapping by API
Gateway. The handler must return
`{"statusCode": ..., "headers": {...}, "body": "..."}` — that exact
shape is the contract, which is why even the earliest placeholder
handlers in this project returned it. Path parameters (like `{code}` in
`GET /{code}`) land at `event["pathParameters"]["code"]`. The request
body, even for JSON requests, arrives as a plain string at
`event["body"]` and has to be `json.loads()`'d manually.

---

## API Gateway

**Q: HTTP API vs. REST API in API Gateway — how did you choose, and
what's the actual difference?**
A: HTTP API is newer, leaner, roughly 70% cheaper, and lower latency,
with fewer configuration knobs than REST API. For a two-route
pass-through service with no request/response transformation and no
scoped custom authorizers, HTTP API is the deliberate fit — REST API's
extra features (usage plans, request validators, VTL mapping templates)
aren't needed here and would just add complexity.

**Q: How does a redirect actually happen under `AWS_PROXY`?**
A: It's just an ordinary proxy response with `statusCode: 302` and a
`Location` header — API Gateway has no special redirect handling of its
own; it passes the response through unmodified, and the client (browser
or curl) is what actually follows the redirect.

---

## CI/CD & OIDC

**Q: Why OIDC federation instead of storing AWS access keys as GitHub
secrets?**
A: A static access key + secret works forever (until manually revoked)
and from anywhere — not just from your GitHub Actions runs. OIDC
federation issues short-lived, per-run credentials instead: for each
workflow run, GitHub's runner presents a freshly-signed identity token to
AWS STS, which verifies it against a role's trust policy and returns
temporary credentials (default 1-hour expiry) scoped to that one role —
nothing is ever stored as a long-lived secret.

**Q: What two things does an IAM OIDC trust policy actually need to get
right, and why is one more important than the other?**
A: (1) Registering the identity provider itself (`aws_iam_openid_connect_provider`,
validated via a certificate thumbprint) — this just tells AWS "tokens
signed by GitHub are cryptographically legitimate." (2) The trust
policy's `Condition` block on the *role*, matching the token's `sub`
claim to a specific repo/branch. #2 is the one that actually enforces
scope — #1 alone would let *any* GitHub Actions workflow from *any* repo
attempt to assume any role that trusts that provider. Get the condition
wrong (too broad, a careless `StringLike` wildcard) and you've built a
hole letting unintended repos impersonate the role.

**Q: [STAR] Walk me through a real bug you debugged in this project.**
A (situation): After building the OIDC trust policy and CI deploy role
with what looked like a completely correct trust policy — verified
directly against the live AWS API — the GitHub Actions deploy job failed
on every single run with `Not authorized to perform
sts:AssumeRoleWithWebIdentity`. (Task): needed to find why AWS was
rejecting a token from a workflow that, on paper, matched the trust
policy's conditions exactly. (Action): first ruled out IAM eventual
consistency by simply retrying the failed job — same failure, so it
wasn't transient. Then, rather than keep guessing at the claim format
from documentation, I added a temporary debug step to the workflow that
requested GitHub's real OIDC token and decoded its JWT payload (just
base64, not encrypted) to print the actual claims. That showed the real
`sub` claim was `repo:owner@ownerId/repo@repoId:ref:refs/heads/main` — an
ID-qualified format, not the plain `repo:owner/repo:ref:...` format the
trust policy was written with. (Result): updated the trust policy's
condition value to the real format, confirmed a successful deploy, then
removed the temporary debug step. The whole investigation is logged with
full command history in [`troubleshooting.md`](./troubleshooting.md) #1.
**Why this is a good story:** it shows methodical elimination (ruled out
the "easy" explanation first), a genuinely useful technique (decode the
actual token instead of trusting documentation/memory), and a fix that
didn't compromise the security posture to "make it work."

**Q: Your `deploy.yml` has two jobs, `validate` and `deploy` — what's
the point of splitting them, and how are they gated differently?**
A: `validate` runs on every push *and* pull request to `main`, needs no
AWS credentials at all (`terraform init -backend=false`, `validate`,
`fmt -check`) — so a PR gets Terraform syntax/formatting feedback before
merge, with zero blast radius. `deploy` adds
`if: github.ref == 'refs/heads/main' && github.event_name == 'push'` and
`needs: validate` — so it only runs after an actual merge to main, and
only if validation passed first.

**Q: Why does `deploy.yml` hardcode Lambda function names and the role
ARN instead of reading them from `terraform output`?**
A: Direct consequence of using local Terraform state (a deliberate
choice for this solo lab) — state lives only in `terraform.tfstate`,
which is `.gitignore`d and never leaves the local machine, so CI has no
remote state to query outputs from. A remote backend (S3 + a lock table)
would let CI run `terraform output` too, keeping identifiers DRY; that's
the real trade-off of the local-state choice, not an oversight.

**Q: Why does the CI job need `permissions: id-token: write` at all?**
A: A GitHub Actions job's default token has no `id-token` permission — a
job must explicitly opt in before it's even allowed to *request* an OIDC
token from GitHub. This is a deliberate security control on GitHub's
side: it prevents any third-party Action running in a workflow from
silently requesting AWS credentials unless the workflow author
explicitly grants that capability.

---

## System design follow-ups (likely "how would you extend this")

**Q: How would you add rate limiting?**
A: API Gateway usage plans + API keys is the lightest-weight option
(much lighter than adding Cognito) — per-key request quotas and
throttling, no application code changes needed. This was scoped as an
explicit stretch goal in the original project plan, not built yet.

**Q: How would you stop short links from living forever?**
A: DynamoDB TTL — add an `expiresAt` attribute (epoch seconds) at write
time and enable TTL on that attribute; DynamoDB automatically deletes
expired items in the background at no extra write cost. Also scoped as
an explicit stretch goal, not yet built.

**Q: How would you add alerting if the service starts failing?**
A: A single CloudWatch alarm on each Lambda's `Errors` metric (or
`4XXError`/`5XXError` on the HTTP API), wired to an SNS topic. Kept to
exactly one alarm deliberately, per the original scope — avoiding alarm
fatigue and unnecessary SNS/subscription plumbing for a lab this size.

**Q: This uses local Terraform state — what changes for a team?**
A: Move to a remote backend (S3 bucket for state + a DynamoDB table for
state locking, so two people/CI runs can't apply concurrently and
corrupt state). This would also let CI read `terraform output` directly
instead of hardcoding function names/ARNs in the workflow, removing the
drift risk that comes with hardcoding.

**Q: How would you scale this to handle a sudden traffic spike?**
A: Both DynamoDB (on-demand) and Lambda scale automatically with no
capacity planning required — the main lever left is Lambda concurrency
limits (default account-level concurrent execution limit could throttle
under a very large spike; can be raised via a support request or
reserved concurrency configured per function). API Gateway HTTP APIs
also scale automatically with no explicit configuration.
