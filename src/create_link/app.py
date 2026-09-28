import json
import logging
import os
import secrets
import string
import time
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

ALLOWED_SCHEMES = {"http", "https"}
MAX_URL_LENGTH = 2048
SHORT_CODE_LENGTH = 7
SHORT_CODE_ALPHABET = string.ascii_letters + string.digits
MAX_PUT_ATTEMPTS = 5

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


class ValidationError(Exception):
    """Raised when the submitted URL fails validation."""


def validate_url(url: str) -> str:
    """Validate a submitted long URL. Returns the trimmed URL, or raises
    ValidationError with a message safe to return to the caller."""
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
    """Generate a random, unguessable short code using a CSPRNG."""
    return "".join(secrets.choice(SHORT_CODE_ALPHABET) for _ in range(length))


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _put_with_unique_code(long_url: str) -> tuple[str, int]:
    """Generate a short code and write the item, retrying on the rare
    collision. Returns (shortCode, createdAt). Raises RuntimeError if it
    can't find a free code."""
    for attempt in range(1, MAX_PUT_ATTEMPTS + 1):
        code = generate_short_code()
        created_at = int(time.time())
        try:
            table.put_item(
                Item={
                    "shortCode": code,
                    "longUrl": long_url,
                    "clicks": 0,
                    "createdAt": created_at,
                },
                ConditionExpression="attribute_not_exists(shortCode)",
            )
            return code, created_at
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                logger.warning("Short code collision on attempt %d: %s", attempt, code)
                continue
            raise
    raise RuntimeError(f"Failed to allocate a unique short code after {MAX_PUT_ATTEMPTS} attempts")


def handler(event, context):
    try:
        raw_body = event.get("body") or "{}"
        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            return _response(400, {"message": "Request body must be valid JSON"})

        try:
            long_url = validate_url(payload.get("url"))
        except ValidationError as e:
            return _response(400, {"message": str(e)})

        short_code, created_at = _put_with_unique_code(long_url)
        logger.info("Created short link %s -> %s", short_code, long_url)

        return _response(
            201,
            {"shortCode": short_code, "longUrl": long_url, "createdAt": created_at},
        )

    except Exception:
        logger.exception("Unhandled error in create_link")
        return _response(500, {"message": "Internal server error"})
