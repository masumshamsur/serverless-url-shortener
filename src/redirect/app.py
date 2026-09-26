import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


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
                logger.info("Short code not found: %s", code)
                return _error_response(404, "Short code not found")
            raise

        long_url = result["Attributes"]["longUrl"]
        logger.info("Redirecting %s -> %s", code, long_url)

        return {
            "statusCode": 302,
            "headers": {"Location": long_url},
            "body": "",
        }

    except Exception:
        logger.exception("Unhandled error in redirect")
        return _error_response(500, "Internal server error")
