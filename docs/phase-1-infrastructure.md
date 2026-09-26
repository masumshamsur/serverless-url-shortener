# Phase 1 — Infrastructure as Code (Terraform)

Goal of this phase: reach a working `terraform apply` for every AWS resource
the app needs, with placeholder Lambda code. No application logic yet — that's
Phase 2.

File layout used:

```
terraform/
├── provider.tf        # Terraform + AWS provider config
├── variables.tf        # inputs (region, project name, retention...)
├── dynamodb.tf         # Links table
├── iam.tf              # Lambda execution role + policy
├── lambda.tf            # 2 functions + log groups
├── apigateway.tf        # HTTP API, routes, integrations, permissions
└── outputs.tf           # API URL, table name, function names
```

---

## Step 1 — Project skeleton, provider, variables

**What was built:** `provider.tf` (Terraform/provider version pins,
`default_tags`) and `variables.tf` (`aws_region`, `project_name`,
`log_retention_days`).

**Commands run:**
```bash
terraform init
terraform validate
terraform plan     # "No changes." — nothing defined yet
```

**Result:** clean init on Terraform v1.16.3, AWS provider v6.66.0, archive
provider v2.8.1. `aws sts get-caller-identity` confirmed account
`842190336606`.

### Concepts introduced

**Terraform state.**
- *What:* `terraform.tfstate` — a JSON file mapping each resource in code to
  the real AWS object (ARN/ID) and its last-known attributes.
- *Why:* `plan` needs to diff *desired* (code) against *actual* (state,
  refreshed from the AWS API). Without state, Terraform has no memory of what
  it already created.
- *How:* `plan` reads code + state, refreshes state from AWS, shows the diff.
  `apply` executes the diff and rewrites state.
- *Here:* local state (a file in `terraform/`), fine for a solo lab. Teams use
  a remote backend (S3 + a lock table) so state is shared and durable.
- *Without it:* Terraform would try to recreate everything on every apply, or
  be unable to update/destroy what it made.
- *Security note:* state can contain secrets in plaintext → always
  `.gitignore`d.

**Provider version constraints.**
- *What:* `required_providers { aws = { version = "~> 6.0" } }` pins the major
  version; `.terraform.lock.hcl` (committed to git) pins the exact version and
  checksums.
- *Why:* a provider major bump can change resource arguments; an unpinned
  provider can make tomorrow's `plan` diverge unexpectedly.
- *Here:* committing the lock file means Phase 3's CI uses the exact same
  provider version as the local machine.

**`default_tags` on the provider block.**
Stamps tags (e.g. `Project`, `ManagedBy`) on every taggable resource
automatically — no need to repeat tags on each resource block.

---

## Step 2 — DynamoDB table

**What was built:** `dynamodb.tf` — one table, `<project_name>-links`,
on-demand billing, partition key `shortCode` (string).

```hcl
resource "aws_dynamodb_table" "links" {
  name         = "${var.project_name}-links"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "shortCode"

  attribute {
    name = "shortCode"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-links"
  }
}
```

**Commands run:**
```bash
terraform apply    # Plan: 1 to add, 0 to change, 0 to destroy.
aws dynamodb describe-table --table-name url-shortener-links \
  --query "Table.{Status:TableStatus,Key:KeySchema}"
```

**Result:** `aws_dynamodb_table.links` created in 11s
(`id=url-shortener-links`). Verified against the live AWS API (not just
Terraform's own plan output) — `describe-table` confirms `TableStatus:
ACTIVE` and `KeySchema: [{AttributeName: shortCode, KeyType: HASH}]`,
matching the Terraform config exactly.

**Status:** ✅ complete.

### Concepts introduced

**DynamoDB is schemaless except for keys.**
- *What:* only attributes used in a key (partition key, sort key, or a
  GSI/LSI key) are declared on the table. Every other attribute
  (`longUrl`, `clicks`, `createdAt`) is just written into an item at write
  time — no table-level schema for it.
- *Why it's different:* unlike SQL, there's no `ALTER TABLE` moment when a new
  field is added later — you just start writing it on new items.
- *Here:* `dynamodb.tf` only declares `shortCode`, even though items will also
  carry `longUrl`, `clicks`, `createdAt`.

**Partition key choice — `shortCode`.**
- *Why this key:* DynamoDB hashes the partition key to route to a physical
  partition; a `GetItem` on `shortCode` is an O(1) point lookup, which is
  exactly what `GET /{code}` needs.
- *No sort key:* each short code maps to exactly one item, so there's no
  need for a range of items under one partition key.

**Billing mode — on-demand (`PAY_PER_REQUEST`) vs provisioned.**
- Provisioned: pre-declare read/write capacity units, pay for that capacity
  whether used or not — cheaper at steady, predictable load.
- On-demand: pay per request, scales instantly, no capacity planning or
  throttling risk.
- *Here:* on-demand, because lab traffic is bursty/unpredictable/near-zero.

**Encryption at rest.**
DynamoDB tables are encrypted by default with an AWS-owned key — no
configuration required, not something omitted by mistake.

**Key type constraint.**
Key attributes can only be `S` (string), `N` (number), or `B` (binary), even
though non-key item values can be richer types (maps, lists, booleans, etc.).

---

## Step 3 — IAM execution role + policy

**What was built:** `iam.tf` — one execution role (`url-shortener-lambda-exec`)
shared by both Lambda functions:
- Trust policy (`assume_role_policy`): only `lambda.amazonaws.com` may assume
  the role.
- `AWSLambdaBasicExecutionRole` (AWS managed) attached for CloudWatch Logs
  permissions.
- One inline policy scoped to exactly the `Links` table ARN, granting only
  `PutItem`, `GetItem`, `UpdateItem`.

```hcl
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.links.arn]
  }
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "${var.project_name}-lambda-dynamodb"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}
```

**Commands run:**
```bash
terraform apply    # 3 to add: role, logs attachment, inline dynamodb policy
aws iam get-role --role-name url-shortener-lambda-exec \
  --query "Role.AssumeRolePolicyDocument"
aws iam get-role-policy --role-name url-shortener-lambda-exec \
  --policy-name url-shortener-lambda-dynamodb --query "PolicyDocument"
```

**Result:** verified against live AWS — trust policy allows only
`lambda.amazonaws.com`; inline policy grants exactly `PutItem`, `GetItem`,
`UpdateItem` scoped to
`arn:aws:dynamodb:us-east-1:842190336606:table/url-shortener-links` (no
wildcards, no other tables).

**Status:** ✅ complete.

### Concepts introduced

**Trust policy vs. permissions policy.**
Every IAM role carries two distinct kinds of policy:
- *Trust policy* (`assume_role_policy`): **who** may assume the role. For
  Lambda, the principal is the AWS service itself (`lambda.amazonaws.com`),
  not a user.
- *Permissions policy* (one or more): **what** the role can do once assumed.

They're separate because "can this identity become this role" and "what can
this role touch" are different questions with different failure modes: a
broken trust policy means the function can't even start; a broken
permissions policy means it starts but fails on its first AWS API call.

**Why not rely solely on an AWS managed policy for DynamoDB.**
`AWSLambdaBasicExecutionRole` (managed) is still attached — every Lambda
needs `CreateLogGroup`/`CreateLogStream`/`PutLogEvents` to emit logs, and
that's generic enough to be a sensible managed policy. But DynamoDB access
must be written by hand, because AWS has no way to know in advance which
table is "yours." A managed policy like `AmazonDynamoDBFullAccess` would
grant access to *every* table in the account — the opposite of least
privilege.

**Resource-level scoping via Terraform interpolation.**
The IAM policy references `aws_dynamodb_table.links.arn` instead of a
hardcoded ARN string. This (a) creates an implicit dependency — Terraform
creates the table before the policy that references its ARN — and (b)
guarantees the policy can never drift from the real resource (no typo'd or
stale ARN).

**Inline policy vs. standalone policy + attachment.**
- `aws_iam_role_policy` (inline): 1:1 tied to a role, deleted with it. Right
  choice for a policy that only ever applies to one role.
- `aws_iam_policy` + `aws_iam_role_policy_attachment`: standalone, reusable,
  independently managed — and the *only* way to attach an AWS-managed policy
  (like the logs policy here), since you can't inline someone else's policy.

**`aws_iam_policy_document` as a Terraform pattern.**
A data source that renders IAM JSON from HCL blocks, validated at plan time
— the idiomatic way to author IAM policies in Terraform, versus hand-written
JSON strings or `jsonencode({...})`.

---

## Step 4 — Lambda functions (placeholder code) + log groups

**What was built:** `lambda.tf` — two functions, `create_link` and
`redirect`, each backed by an `archive_file` zip of a placeholder Python
handler (`src/create_link/app.py`, `src/redirect/app.py`), each with its own
explicit `aws_cloudwatch_log_group` (14-day retention, from
`var.log_retention_days`) created before the function via `depends_on`.
Runtime `python3.13` on `arm64`. Table name injected via the `TABLE_NAME`
environment variable rather than hardcoded in Python.

```hcl
data "archive_file" "create_link" {
  type        = "zip"
  source_dir  = "${path.module}/../src/create_link"
  output_path = "${path.module}/build/create_link.zip"
}

resource "aws_cloudwatch_log_group" "create_link" {
  name              = "/aws/lambda/${var.project_name}-create-link"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "create_link" {
  function_name    = "${var.project_name}-create-link"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "app.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.create_link.output_path
  source_code_hash = data.archive_file.create_link.output_base64sha256
  timeout          = 5

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.links.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.create_link]
}
# redirect follows the same shape
```

**Commands run:**
```bash
terraform plan     # Plan: 4 to add (2 log groups + 2 functions)
terraform apply
aws lambda invoke --function-name url-shortener-create-link --payload '{}' \
  --cli-binary-format raw-in-base64-out out.json && cat out.json
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/url-shortener \
  --query "logGroups[].{Name:logGroupName,Retention:retentionInDays}"
```

**Result:** invoke returned Lambda-level `StatusCode: 200` (function executed
without error) with application body `{"statusCode": 501, "body":
"{\"message\": \"create_link not yet implemented\"}"}` (our placeholder,
correctly returned). Both log groups confirmed at 14-day retention via the
live API.

**Status:** ✅ complete.

### Concepts introduced

**Deployment packages via the `archive` provider.**
Lambda requires a zip of the code, not a raw directory. `data "archive_file"`
(from `hashicorp/archive`, pinned in Step 1) zips a source directory at
plan/apply time — no manual `zip` step, and Terraform gets the zip's content
hash for free.

**`source_code_hash` — how Terraform detects code changes.**
`aws_lambda_function.source_code_hash` is set to
`archive_file.xxx.output_base64sha256`. Without it, Terraform only notices a
redeploy is needed when a resource *argument* changes (memory, timeout,
etc.) — it has no way to see that the zip's *bytes* changed otherwise. This
is what makes "edit Python → `terraform apply`" actually redeploy the code
in Phase 2.

**Log group must be created explicitly, before the function.**
If you don't pre-create a Lambda's log group, AWS auto-creates one on first
invocation with **never-expire retention** — a quiet cost/hygiene trap.
Declaring `aws_cloudwatch_log_group` explicitly (with our own
`log_retention_days`) and forcing it to exist first via `depends_on` avoids
the implicit auto-created group winning the race.

**Runtime/architecture choice: `python3.13` on `arm64`.**
ARM (Graviton2) Lambda is generally ~20% cheaper and often faster than x86
for typical workloads, with zero code changes required for pure-Python code
with no compiled native dependencies.

**Environment variables over hardcoded config.**
`TABLE_NAME` is injected from `aws_dynamodb_table.links.name` rather than
hardcoded as a string in Python. Keeps the table name single-sourced in
Terraform, and makes the same code portable across environments with zero
code changes.

**Lambda's own status vs. the application's status.**
`aws lambda invoke`'s `StatusCode: 200` only means "Lambda successfully
executed your handler without an unhandled exception." It's independent of
whatever HTTP-style status code your handler's return value contains (here,
`501`, our own placeholder). Conflating the two is a common source of
confusion when debugging.

---

## Step 5 — HTTP API, routes, integrations, permissions

**What was built:** `apigateway.tf` — one `aws_apigatewayv2_api` (HTTP API,
not REST API), a `$default` auto-deploy stage, and per-route
integration + route + Lambda resource-policy permission for each of the two
routes (`POST /links` → `create_link`, `GET /{code}` → `redirect`), all using
`AWS_PROXY` integration type.

```hcl
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "create_link" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.create_link.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_link" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /links"
  target    = "integrations/${aws_apigatewayv2_integration.create_link.id}"
}

resource "aws_lambda_permission" "create_link" {
  statement_id  = "AllowAPIGatewayInvokeCreateLink"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_link.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
# redirect follows the same shape, route_key = "GET /{code}"
```

**Commands run:**
```bash
terraform plan     # Plan: 8 to add
terraform apply    # Apply complete! Resources: 8 added
aws apigatewayv2 get-apis --query "Items[?Name=='url-shortener-api'].ApiEndpoint" --output text
curl -i -X POST https://<endpoint>/links
curl -i https://<endpoint>/abc123
```

**Result:** endpoint `https://fpzqe4wtn9.execute-api.us-east-1.amazonaws.com`.
Both routes returned `HTTP/2 501` with the correct placeholder JSON body —
confirmed end-to-end over real HTTP: client → API Gateway → Lambda proxy
integration → resource policy → function. Noted: `content-type: text/plain`
on both responses, since the placeholder handler doesn't set a
`Content-Type` header — to be fixed with an explicit header in Phase 2's
real handlers.

**Status:** ✅ complete.

### Concepts introduced

**HTTP API vs. REST API.**
API Gateway has two product lines: "REST API" (older, feature-rich, pricier)
and "HTTP API" (newer, leaner, ~70% cheaper, lower latency, fewer knobs).
For a two-route pass-through service with no request/response
transformation or scoped custom authorizers, HTTP API is the deliberate
choice. Terraform's `aws_apigatewayv2_*` resources are this generation — the
"v2" names the API Gateway service generation, not an API version being
exposed to clients.

**Lambda proxy integration (`AWS_PROXY`).**
Rather than API Gateway mapping request/response fields individually, a
proxy integration hands Lambda the entire raw HTTP request (method, path,
headers, query string, body) as one JSON event, and expects back
`{statusCode, headers, body}`. That's why the placeholder handlers already
return that shape — it's the contract `AWS_PROXY` requires, not an arbitrary
choice.

**Route key syntax and path parameters.**
`"GET /{code}"` declares `{code}` as a path parameter; its value lands in
the Lambda event at `event["pathParameters"]["code"]` — used in Phase 2 to
know which short code was requested.

**Resource-based Lambda permissions (`aws_lambda_permission`).**
The IAM execution role (Step 3) governs what Lambda *can do* once running —
nothing about who may *invoke* it. Letting API Gateway invoke a function
requires a separate, resource-based policy statement on the function itself,
granting `lambda:InvokeFunction` to `apigateway.amazonaws.com`, scoped via
`source_arn` to this API. Missing this is one of the most common HTTP
API + Lambda debugging traps: everything looks wired correctly, but
API Gateway gets a 500 "not authorized" error back.

**`source_arn` wildcard scoping.**
`"${execution_arn}/*/*"` — the two wildcards are stage and route
(method+path): "any stage, any route on this API may invoke this function."
Can be scoped tighter per-route (e.g. `/*/POST/links`), but since each
Lambda here only ever serves one route, the broader form costs nothing in
practice.

**Auto-deploy stages.**
An HTTP API needs a "stage" (an addressable deployment, e.g. `$default`) to
be invokable at all. `auto_deploy = true` means every route/integration
change goes live immediately — right for a lab; production APIs often use
named stages with manual or CI-gated deploys.

---

## Step 6 — Outputs

**What was built:** `outputs.tf` — four outputs: `api_endpoint`,
`table_name`, `create_link_function_name`, `redirect_function_name`.

```hcl
output "api_endpoint" {
  description = "Base invoke URL for the HTTP API"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "table_name" {
  description = "DynamoDB table name for links"
  value       = aws_dynamodb_table.links.name
}

output "create_link_function_name" {
  description = "Lambda function name for the create_link handler"
  value       = aws_lambda_function.create_link.function_name
}

output "redirect_function_name" {
  description = "Lambda function name for the redirect handler"
  value       = aws_lambda_function.redirect.function_name
}
```

**Commands run:**
```bash
terraform apply    # 0 added/changed/destroyed — outputs aren't infra
terraform output
```

**Result:**
```
api_endpoint = "https://fpzqe4wtn9.execute-api.us-east-1.amazonaws.com"
create_link_function_name = "url-shortener-create-link"
redirect_function_name = "url-shortener-redirect"
table_name = "url-shortener-links"
```
Matches the endpoint already verified by curl in Step 5.

**Status:** ✅ complete.

### Concepts introduced

**Why declare outputs instead of re-querying via the AWS CLI.**
1. `terraform output` is faster than re-deriving an ARN/URL via CLI queries
   each time.
2. Other Terraform configs/modules can read *only* the declared outputs via
   a `terraform_remote_state` data source, instead of the entire (possibly
   sensitive) state file.
3. In Phase 3, CI needs the function names to know what to deploy — an
   output is an explicit, drift-proof contract for that, instead of
   hardcoding names in the workflow that could diverge from Terraform.

**Outputs vs. resource changes in `apply`'s summary line.**
The `Resources: X added, Y changed, Z destroyed` line only counts resources
— output changes are reported separately (as "Changes to Outputs:" in
`plan`) and don't move that counter, even when outputs are being added for
the first time.

---

## Phase 1 wrap-up

All infrastructure exists and is verified end-to-end with placeholder
application logic:

- ✅ DynamoDB table `url-shortener-links`, on-demand, partition key
  `shortCode`
- ✅ IAM execution role, least-privilege, scoped to exactly this table
- ✅ 2 Lambda functions (`create_link`, `redirect`), Python 3.13 on arm64,
  explicit log groups at 14-day retention
- ✅ HTTP API with 2 routes, `AWS_PROXY` integrations, resource-based
  invoke permissions
- ✅ Outputs for API endpoint, table name, function names

Verified with real AWS API calls throughout (not just Terraform's own plan
output): `describe-table`, `get-role`/`get-role-policy`, `lambda invoke`,
`describe-log-groups`, and curl against the live HTTP API.

**Next:** Phase 2 — real Python application logic (short-code generation,
`PutItem`, atomic `UpdateItem` click counter, validation, 404s, error
handling), redeployed via `terraform apply` and tested end-to-end with curl.
