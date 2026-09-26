# Phase 2 — Application Code (Python Lambda)

Goal of this phase: replace the Phase 1 placeholder Lambda code with real
logic, redeploy via `terraform apply`, and test end-to-end with curl.

**Design decision:** short codes are **random**, not hash-based. A hash of
the long URL would be deterministic (same URL → same code always), which
forecloses shortening the same URL twice under different codes, and leaks
structure about the hashing scheme. Random codes are unguessable and
URL-content-independent, at the cost of needing an explicit uniqueness
check on write (handled via a conditional `PutItem` in Step 2).

---

## Step 1 — Short-code generation + URL validation

**What was built:** `src/create_link/app.py` — two pure helper functions,
`generate_short_code()` and `validate_url()`, tested locally with no AWS
involved. `handler` still returns the Phase 1 placeholder; real wiring is
Step 2.

```python
import secrets
import string
from urllib.parse import urlparse

ALLOWED_SCHEMES = {"http", "https"}
MAX_URL_LENGTH = 2048
SHORT_CODE_LENGTH = 7
SHORT_CODE_ALPHABET = string.ascii_letters + string.digits


class ValidationError(Exception):
    """Raised when the submitted URL fails validation."""


def validate_url(url: str) -> str:
    if not url or not isinstance(url, str):
        raise ValidationError("A 'url' field is required")
    url = url.strip()
    if len(url) > MAX_URL_LENGTH:
        raise ValidationError(f"URL exceeds max length of {MAX_URL_LENGTH} characters")
    parsed = urlparse(url)
    if parsed.scheme not in ALLOWED_SCHEMES:
        raise ValidationError("URL must start with http:// or https://")
    if not parsed.netloc:
        raise ValidationError("URL must include a host")
    return url


def generate_short_code(length: int = SHORT_CODE_LENGTH) -> str:
    return "".join(secrets.choice(SHORT_CODE_ALPHABET) for _ in range(length))
```

**Commands run (local, no AWS/Terraform needed for this step):**
```bash
cd src/create_link
python3 -c "
from app import generate_short_code, validate_url, ValidationError
codes = [generate_short_code() for _ in range(5)]
print('codes:', codes)
print('all length 7:', all(len(c) == 7 for c in codes))
print('all unique:', len(set(codes)) == len(codes))
print(validate_url('https://example.com/some/path?x=1'))
for bad in ['javascript:alert(1)', 'http://', 'ftp://example.com', '', 'x' * 3000]:
    try:
        validate_url(bad)
        print('FAILED TO REJECT:', bad[:30])
    except ValidationError as e:
        print('correctly rejected:', repr(bad[:30]), '->', e)
"
```

**Result:** 5 distinct 7-character codes generated; valid URL passed through
unchanged; all 5 invalid cases correctly rejected —
`javascript:` scheme, `http://` with no host, disallowed `ftp` scheme,
empty string, and over-length string each raised `ValidationError` with an
appropriate message.

**Status:** ✅ complete.

### Concepts introduced

**`secrets` module vs. `random` module.**
`random` is a deterministic PRNG (Mersenne Twister) — predictable if enough
output is observed. `secrets` draws from the OS's cryptographically-secure
random source. For a public "generate an unguessable identifier" use case,
`secrets` is the right default — the threat being defended against is
*enumeration* (guessing/iterating other users' short codes), not brute-force
login attacks.

**Code length and the birthday bound.**
A 62-character alphabet at length 7 gives `62^7 ≈ 3.5 trillion` possible
codes. The relevant collision math isn't the total space size but the
birthday paradox: roughly `√(62^7) ≈ 1.87 million` codes would need to be
generated before a 50% chance of *any* collision. Astronomically unlikely
for a lab — but "very unlikely" isn't "impossible," so correctness still
requires an explicit uniqueness check on write (a conditional `PutItem`,
Step 2), rather than assuming probability alone protects it.

**URL validation beyond "is this syntactically a URL."**
This is a redirect service: any accepted URL will later be sent to a
browser via a `Location` header. Two things must be rejected: a
missing host (a string that parses without erroring but has no real
destination, e.g. `http://`), and non-`http(s)` schemes like `javascript:`
or `file:` — accepting those would let the service issue malicious
redirects under a URL that looks legitimate. Validating strictly at
creation time is cheap insurance against a problem that's expensive to
fix after the fact.

---

## Step 2 — Wired-up `create_link` handler

**What was built:** full `handler()` in `src/create_link/app.py` — parses
the `AWS_PROXY` event body, validates via `validate_url`, writes to
DynamoDB with a collision-guarded conditional `PutItem`
(`_put_with_unique_code`, retrying up to `MAX_PUT_ATTEMPTS` on a
`ConditionalCheckFailedException`), logs via the `logging` module, and
returns a JSON response (`_response` helper) with the right status code for
each of: malformed JSON body (400), validation failure (400), success
(201), or unhandled exception (500, generic message only — full detail
logged).

`boto3.resource("dynamodb")` and the `Table` handle are created at **module
level** (outside `handler`), so they're reused across warm invocations of
the same execution environment instead of being rebuilt per request.

**Commands run:**
```bash
cd terraform
terraform plan     # Plan: 1 to change (create_link's source_code_hash)
terraform apply

curl -i -X POST https://<endpoint>/links -H "Content-Type: application/json" \
  -d '{"url": "https://www.google.com"}'
curl -i -X POST https://<endpoint>/links -H "Content-Type: application/json" \
  -d '{"url": "javascript:alert(1)"}'
curl -i -X POST https://<endpoint>/links -H "Content-Type: application/json" \
  -d 'not json'

aws dynamodb scan --table-name url-shortener-links --max-items 5
```

**Result:** success case returned `201` with
`{"shortCode": "ieGQcDf", "longUrl": "https://www.google.com"}` and
`content-type: application/json` (the header fix from Step 1's Phase-1 note
landed correctly). Both failure cases returned `400` with distinct,
specific messages (invalid scheme; malformed JSON). `scan` confirmed the
item persisted with the correct shape: `shortCode` (S), `longUrl` (S),
`clicks: 0` (N), `createdAt` (N, unix timestamp).

**Status:** ✅ complete.

### Concepts introduced

**Parsing the `AWS_PROXY` event body.**
The request body arrives as a **string** at `event["body"]`, even for a
JSON request — it must be `json.loads()`'d explicitly. It can also be
`None` (no body sent) or base64-encoded (when
`event.get("isBase64Encoded")` is `True`, e.g. binary payloads); real
handlers need to account for both, not just the happy path.

**Conditional writes, concretely.**
```python
table.put_item(Item={...}, ConditionExpression="attribute_not_exists(shortCode)")
```
Tells DynamoDB to fail the write atomically if an item with that key already
exists, rather than silently overwriting it. The failure surfaces as
`ClientError` with `e.response["Error"]["Code"] ==
"ConditionalCheckFailedException"`, caught specifically so a retry with a
new code can happen — bounded by `MAX_PUT_ATTEMPTS` so a persistent failure
doesn't loop forever.

**Boto3 resource API vs. client API.**
`boto3.resource("dynamodb")` → Pythonic, native types
(`table.put_item(Item={...})`). `boto3.client("dynamodb")` → lower-level,
requires explicit DynamoDB type descriptors (`{"S": "value"}`). Resource API
is the standard choice for application code like this.

**Module-level SDK clients for warm-invocation reuse.**
Lambda reuses the same execution environment across "warm" invocations, so
code outside `handler()` runs once per environment, not once per request.
Expensive-to-create, reusable objects (SDK clients, DB connections) belong
at module level; per-request values belong inside `handler`.

**Structured logging via the `logging` module.**
Available by default in the Lambda runtime, and everything written to
stdout/stderr (including from `print()`) ends up in CloudWatch regardless —
but `logging` adds levels (`INFO`/`WARNING`/`ERROR`) that become filterable
once there's real traffic to sift through in CloudWatch Logs Insights.

**Three-way error handling shape.**
Validation failure → 400, client-facing message says why. Unexpected
failure → 500, generic client message, full exception logged via
`logger.exception` (never leak stack traces or internal details to the
response). Success → 201 (not 200 — signals "a resource was created").

---

## Step 3 — `redirect` handler: atomic click counter, 404, 302

**What was built:** full `handler()` in `src/redirect/app.py` — reads
`event["pathParameters"]["code"]`, performs a single atomic
`UpdateItem` that both increments `clicks` and returns the full updated
item (`longUrl` included), converts a missing code into a clean 404 via
`ConditionExpression="attribute_exists(shortCode)"`, and returns a real
`302` with a `Location` header on success.

```python
def handler(event, context):
    try:
        code = event.get("pathParameters", {}).get("code")
        if not code:
            return _error_response(400, "Missing short code")

        try:
            result = table.update_item(
                Key={"shortCode": code},
                UpdateExpression="ADD clicks :incr",
                ExpressionAttributeValues={":incr": 1},
                ConditionExpression="attribute_exists(shortCode)",
                ReturnValues="ALL_NEW",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return _error_response(404, "Short code not found")
            raise

        long_url = result["Attributes"]["longUrl"]
        return {
            "statusCode": 302,
            "headers": {"Location": long_url},
            "body": "",
        }
    except Exception:
        logger.exception("Unhandled error in redirect")
        return _error_response(500, "Internal server error")
```

**Commands run:**
```bash
cd terraform
terraform plan     # Plan: 1 to change (redirect's source_code_hash)
terraform apply

curl -i https://<endpoint>/ieGQcDf                       # expect 302
curl -o /dev/null -s https://<endpoint>/ieGQcDf           # x2 more hits
aws dynamodb get-item --table-name url-shortener-links \
  --key '{"shortCode": {"S": "ieGQcDf"}}'
curl -i https://<endpoint>/doesnotexist                   # expect 404
```

**Result:** `302` with `location: https://www.google.com`; after 3 total
requests to the same code, `clicks` read back as exactly `3` from
DynamoDB directly (proving no lost updates across separate invocations);
unknown code returned a clean `404` with
`{"message": "Short code not found"}`.

**Status:** ✅ complete.

### Concepts introduced

**Atomic increment via `UpdateItem` `ADD`, vs. read-modify-write.**
A naive `GetItem` → add 1 in Python → `PutItem` has a race: two concurrent
requests can both read `clicks: 5`, both compute `6`, and one increment is
lost. `UpdateItem` with `ADD clicks :incr` performs the increment inside
DynamoDB itself, atomically — no read-modify-write round trip, no lost
updates, no application-level locking.

**One round trip for both the increment and the read.**
`ReturnValues="ALL_NEW"` on the same `UpdateItem` call returns the complete
updated item (including `longUrl`) alongside the increment — one DynamoDB
call total, not `GetItem` + separate `UpdateItem`. Also closes a
TOCTOU-style gap: no window between "check it exists" and "increment" where
the item could be deleted in between two separate calls.

**`ConditionExpression="attribute_exists(...)"` for a clean 404.**
Without this, `UpdateItem`'s `ADD` defaults to upsert semantics — hitting a
nonexistent code would silently *create* a garbage item (`clicks: 1`, no
`longUrl`) instead of failing. Requiring `attribute_exists` turns "not
found" into the same `ConditionalCheckFailedException` pattern used for
collision detection in Step 2, caught and converted into a proper 404.

**302 responses under `AWS_PROXY`.**
A redirect is just an ordinary proxy response with `statusCode: 302` and a
`Location` header — API Gateway passes headers straight through with no
special redirect handling of its own; the client (browser/curl) is what
actually follows it.

---

## Step 4 — End-to-end flow test

**What was tested:** the full user-facing flow in one sequence, not the
individual pieces tested separately in Steps 2–3 — create a link, follow
the redirect via `curl -L`, confirm the click counter.

**Commands run:**
```bash
curl -s -X POST https://<endpoint>/links -H "Content-Type: application/json" \
  -d '{"url": "https://docs.aws.amazon.com/lambda/"}' | tee /tmp/create_response.json

CODE=$(python3 -c "import json; print(json.load(open('/tmp/create_response.json'))['shortCode'])")
curl -sL -o /dev/null -w "Final URL: %{url_effective}\nHTTP status chain: %{http_code}\n" \
  https://<endpoint>/$CODE

aws dynamodb get-item --table-name url-shortener-links \
  --key "{\"shortCode\": {\"S\": \"$CODE\"}}"
```

**Result:** created `shortCode: xdLkw5Z`; `curl -L` followed the `302` and
landed on `https://docs.aws.amazon.com/lambda/` with a final `200`;
DynamoDB confirmed `clicks: 1`.

**Status:** ✅ complete.

---

## Phase 2 wrap-up

Both Lambda functions now hold real application logic, deployed via
`terraform apply` and verified against the live API:

- ✅ `create_link`: validates the submitted URL, generates a random
  CSPRNG-based short code, writes to DynamoDB with a collision-guarded
  conditional `PutItem`, returns 201/400/500 as appropriate
- ✅ `redirect`: atomically increments the click counter and reads the
  target URL in a single `UpdateItem` call, returns 302/404/500 as
  appropriate
- ✅ Full create → redirect → click-count flow verified end-to-end in one
  sequence, not just piecemeal

**Next:** Phase 3 — git, GitHub, the OIDC identity provider + narrowly
scoped IAM role, and a `deploy.yml` that validates Terraform (no AWS creds)
and deploys Lambda code (OIDC-assumed creds) on push to `main`.
