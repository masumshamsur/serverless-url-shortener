# Concepts Glossary

Flat reference of every new concept introduced in this lab, in the order it
came up. Each entry: what it is, why it's needed, and what breaks without it.
Meant for quick interview review — full context for each lives in the
matching phase doc.

## Phase 1 — Infrastructure

### Terraform state
A JSON file (`terraform.tfstate`) mapping resources in code to real AWS
objects and their last-known attributes. `plan` diffs desired (code) vs.
actual (state, refreshed from AWS); without it Terraform has no memory of
what it already created. Contains secrets sometimes → never committed to git.
Local state is fine solo; teams use a remote backend (e.g. S3 + a lock table)
for shared, durable state.

### Provider version pinning
`required_providers { aws = { version = "~> 6.0" } }` pins the major version;
`.terraform.lock.hcl` (committed) pins the exact version + checksums so local
and CI runs use identical provider behavior.

### `default_tags`
Provider-level block that stamps tags on every taggable resource
automatically, avoiding repetition per-resource.

### DynamoDB schemaless design
Only key attributes (partition/sort/GSI/LSI keys) are declared on the table.
All other item attributes are freeform at write time — no `ALTER TABLE`
equivalent needed to add a new field later.

### DynamoDB partition key selection
The partition key is hashed by DynamoDB to route to a physical partition. A
`GetItem` on the partition key is an O(1) point lookup. Choose the key that
matches your primary access pattern — here, `shortCode`, because the hot path
(`GET /{code}`) looks up by that exact value. No sort key needed since each
partition key maps to exactly one item.

### DynamoDB billing modes
- **Provisioned:** pre-declared read/write capacity, pay whether used or not
  — cheaper at steady, predictable load.
- **On-demand (`PAY_PER_REQUEST`):** pay per request, scales instantly, no
  capacity planning or throttling risk — right fit for bursty/unpredictable
  lab traffic.

### DynamoDB key attribute types
Key attributes are constrained to `S` (string), `N` (number), or `B`
(binary) — even though non-key item values can be richer types (maps, lists,
booleans, etc.).

### IAM trust policy vs. permissions policy
Trust policy (`assume_role_policy`) = who can assume the role (for Lambda,
the `lambda.amazonaws.com` service principal). Permissions policy = what the
role can do once assumed. Broken trust policy → function can't start; broken
permissions policy → function starts but fails on its first AWS API call.

### Least privilege over AWS managed policies
Generic, low-risk permissions (e.g. CloudWatch Logs write access) are fine as
an AWS managed policy (`AWSLambdaBasicExecutionRole`). Anything scoped to a
specific resource you own (e.g. one DynamoDB table) should be a hand-written
policy limited to that resource's ARN — a broad managed policy like
`AmazonDynamoDBFullAccess` would grant access to every table in the account.

### IAM policy scoping via Terraform interpolation
Referencing `aws_dynamodb_table.links.arn` in a policy (instead of a
hardcoded ARN string) creates an implicit dependency (table created first)
and guarantees the policy can't drift from the real resource.

### Inline IAM policy vs. standalone policy + attachment
`aws_iam_role_policy` (inline): 1:1 with a role, deleted with it — right for
a policy that only ever applies to one role. `aws_iam_policy` +
`aws_iam_role_policy_attachment`: standalone/reusable, and the only way to
attach an AWS-managed policy (can't inline someone else's policy).

### `aws_iam_policy_document` data source
Renders IAM JSON from HCL blocks, validated at plan time — the idiomatic
Terraform pattern for authoring IAM policies, vs. hand-written JSON strings.

### `archive_file` deployment packages
Lambda needs a zip, not a directory. The `archive` provider's
`archive_file` data source zips a source directory at plan/apply time and
exposes a content hash — no manual `zip` step.

### `source_code_hash` and redeploy detection
Setting `aws_lambda_function.source_code_hash` to the zip's
`output_base64sha256` is what lets Terraform detect that the *code* changed
(not just a resource argument) and trigger a redeploy on `apply`.

### Explicit CloudWatch log group creation for Lambda
If not pre-created, AWS auto-creates a Lambda's log group on first
invocation with never-expire retention. Declaring
`aws_cloudwatch_log_group` explicitly (with a real retention value) and
sequencing it before the function via `depends_on` avoids that.

### ARM (Graviton2) vs. x86 Lambda
`architectures = ["arm64"]` is generally ~20% cheaper and often faster for
typical workloads, with no code changes needed for pure-Python code with no
compiled native dependencies.

### Lambda environment variables over hardcoded config
Injecting config (e.g. a table name) as a Lambda environment variable
sourced from a Terraform resource attribute (`aws_dynamodb_table.links.name`)
keeps it single-sourced and makes code portable across environments.

### Lambda invoke status vs. application status
`aws lambda invoke`'s `StatusCode: 200` only confirms the handler ran
without an unhandled exception — it says nothing about the HTTP-style status
code your own return value contains. Two independent layers.

### HTTP API vs. REST API (API Gateway)
Two distinct API Gateway product lines: REST API (older, feature-rich,
pricier) and HTTP API (newer, leaner, ~70% cheaper, lower latency, fewer
knobs). HTTP API is the right fit for a simple pass-through service with no
transformation/authorizer needs. Terraform's `aws_apigatewayv2_*` = this
generation.

### Lambda proxy integration (`AWS_PROXY`)
Hands the Lambda function the entire raw HTTP request as one JSON event and
expects `{statusCode, headers, body}` back — no field-by-field mapping by
API Gateway. This is why proxy-integrated handlers must return that exact
shape.

### API Gateway route path parameters
`"GET /{code}"` makes `{code}` available in the Lambda event at
`event["pathParameters"]["code"]`.

### Resource-based Lambda permissions (`aws_lambda_permission`)
Separate from the IAM execution role. The execution role governs what
Lambda can do once running; a resource-based policy on the function itself
governs who may invoke it. API Gateway needs an explicit
`lambda:InvokeFunction` grant to `apigateway.amazonaws.com`, scoped via
`source_arn`. Forgetting this is a classic "everything looks right but I get
a 500" trap.

### Auto-deploy stages (API Gateway HTTP API)
An HTTP API needs an addressable "stage" (e.g. `$default`) to be invokable.
`auto_deploy = true` pushes every route/integration change live immediately
— fine for a lab, often replaced by named/CI-gated stages in production.

### Terraform outputs
Explicit, named values surfaced from state — faster than re-deriving via CLI
queries, consumable by other configs via `terraform_remote_state` without
exposing full state, and a drift-proof contract for CI (e.g. Phase 3 reading
function names to know what to deploy). Output changes are reported
separately from the `Resources: X added/changed/destroyed` summary line.

---

## Phase 2 — Application code

### Random vs. hash-based short codes
Random: unguessable, URL-content-independent, needs an explicit uniqueness
check on write. Hash-based (e.g. first N chars of a URL's SHA256):
deterministic (same URL → same code always), which forecloses re-shortening
the same URL under a different code, and leaks hashing-scheme structure.
Chose random for this project.

### `secrets` vs. `random` for identifier generation
`random` is a deterministic PRNG, predictable given enough observed output.
`secrets` draws from the OS's CSPRNG. Use `secrets` for anything
unguessable-by-design (tokens, short codes), even when it's not a password —
the threat model is enumeration, not just brute force.

### Birthday bound for collision risk
For a random identifier space of size `N`, expect a 50% chance of any
collision after roughly `√N` generations — not after `N` generations. Drives
the decision to still handle collisions explicitly (e.g. a conditional
write) even when the space is huge.

### Validating URLs meant for redirection
A redirect service must reject more than "malformed" URLs: also reject
missing-host URLs (parse without erroring but have no real destination)
and non-http(s) schemes (`javascript:`, `file:`, etc.), since accepted URLs
are later placed directly into a `Location` header sent to a browser.

### Parsing the AWS_PROXY event body
`event["body"]` is always a string, even for JSON requests — call
`json.loads()` explicitly. It may also be `None` (no body) or
base64-encoded (`event["isBase64Encoded"] is True`, for binary payloads).

### Conditional writes for uniqueness (DynamoDB)
`ConditionExpression="attribute_not_exists(shortCode)"` on `PutItem` makes
DynamoDB fail the write atomically instead of silently overwriting an
existing item with the same key. The failure surfaces as
`ConditionalCheckFailedException`, catchable specifically to trigger a
bounded retry with a new key.

### Boto3 resource API vs. client API
`resource("dynamodb")`: Pythonic, native Python types. `client("dynamodb")`:
lower-level, requires explicit DynamoDB type descriptors (`{"S": "value"}`).
Resource API is the default for application code.

### Module-level SDK clients in Lambda
Code outside `handler()` runs once per warm execution environment, not once
per request — so expensive, reusable objects (SDK clients, DB connections)
belong at module level, not inside the handler.

### `logging` module vs. `print()` in Lambda
Both end up in CloudWatch, but `logging` adds levels
(`INFO`/`WARNING`/`ERROR`) that become filterable in CloudWatch Logs
Insights once there's real traffic.

### Three-way Lambda error handling shape
Validation failure → 400 with a specific client-facing message. Unexpected
failure → 500 with a generic message (never leak stack traces/internals);
log the real exception via `logger.exception`. Success → the specific 2xx
that fits (e.g. 201 for "created", not a generic 200).

### Atomic increment via DynamoDB `UpdateItem` `ADD`
Increments happen inside DynamoDB itself (`UpdateExpression="ADD clicks
:incr"`), not via read-in-app-then-write. Avoids the lost-update race of a
`GetItem` → add 1 → `PutItem` sequence under concurrent requests, with no
application-level locking needed.

### Combining a write and a read in one DynamoDB call
`ReturnValues="ALL_NEW"` on `UpdateItem` returns the full updated item
alongside the write — avoids a separate `GetItem`, and closes the gap where
a two-call sequence could race against a delete in between.

### `ConditionExpression="attribute_exists(...)"` to prevent upsert-by-accident
`UpdateItem`'s `ADD` (and update expressions generally) default to upsert
semantics — they'll create the item if the key doesn't exist. Requiring
`attribute_exists` turns "key not found" into a catchable
`ConditionalCheckFailedException` instead of silently creating garbage
data.

### HTTP redirects under API Gateway `AWS_PROXY`
No special redirect handling by API Gateway — a 302 is just a normal proxy
response (`statusCode: 302`, `Location` header) passed straight through;
the client is what follows it.

---

## Phase 3 — CI/CD

*(to be filled in as Phase 3 progresses)*
