#!/usr/bin/env python3
"""
Dispatcher: GitHub `workflow_job` webhook -> `run-microvm`.

Deployed as a Lambda function behind a Lambda Function URL (auth NONE).
Authentication is the webhook's HMAC signature (X-Hub-Signature-256),
verified against a shared secret held in Secrets Manager - the same model
GitHub itself prescribes for webhook receivers. An API Gateway in front
would add cost and moving parts without adding any authorization we could
actually use here (GitHub can't sign SigV4).

Flow:
  1. Verify the HMAC signature over the *raw* body (reject -> 401).
  2. Ignore everything except `workflow_job` with action `queued`.
  3. Ignore jobs from other repositories (defense in depth - the webhook
     should only be installed on the target repo anyway).
  4. Ignore jobs whose labels aren't a subset of our runner's labels -
     this mirrors GitHub's own runner-to-job matching rule, so we launch
     exactly when one of our runners *could* pick the job up.
  5. `run_microvm` - the MicroVM's /run hook does the rest (see
     ../runner-image/hook_server.py), including self-terminate.

Known gaps (accepted for now, documented in ../README.md):
  - A webhook redelivery or a job cancelled while queued leaves one
    surplus MicroVM idling until maximum-duration reaps it. One VM's
    idle cost is the blast radius; no dedup state is kept.
  - No queue/concurrency logic: one queued job = one run_microvm call.
"""

import base64
import hashlib
import hmac
import json
import logging
import os

import boto3

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("dispatcher")

WEBHOOK_SECRET_ARN = os.environ["WEBHOOK_SECRET_ARN"]
MICROVM_IMAGE_ARN = os.environ["MICROVM_IMAGE_ARN"]
MICROVM_EXECUTION_ROLE_ARN = os.environ["MICROVM_EXECUTION_ROLE_ARN"]
MICROVM_MAX_DURATION_SECONDS = int(os.environ["MICROVM_MAX_DURATION_SECONDS"])
ALLOWED_REPO = os.environ["ALLOWED_REPO"].lower()  # "owner/repo"
RUNNER_LABELS = {
    label.strip().lower()
    for label in os.environ["RUNNER_LABELS"].split(",")
    if label.strip()
}

# Module-level clients: created once per execution environment. Classic
# Lambda DOES inject AWS_REGION (unlike Lambda MicroVMs - see the region
# saga in ../runner-image/hook_server.py), so no explicit region needed.
_secretsmanager = boto3.client("secretsmanager")
_microvms = boto3.client("lambda-microvms")

_webhook_secret_cache = None


def _webhook_secret():
    """Fetch (once per execution environment) the raw webhook secret string.

    Rotation note: rotating the secret requires new Lambda execution
    environments to pick it up - update the GitHub webhook secret and the
    Secrets Manager value, then wait out (or force, e.g. by republishing
    the function) the old warm environments.
    """
    global _webhook_secret_cache
    if _webhook_secret_cache is None:
        resp = _secretsmanager.get_secret_value(SecretId=WEBHOOK_SECRET_ARN)
        _webhook_secret_cache = resp["SecretString"].strip()
    return _webhook_secret_cache


def _response(status, message):
    # GitHub only cares about 2xx vs non-2xx (non-2xx shows the delivery as
    # failed and makes manual "Redeliver" available). Keep bodies terse -
    # they are visible in the repo's webhook delivery log.
    return {"statusCode": status, "body": json.dumps({"message": message})}


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body") or ""
    body = (
        base64.b64decode(raw_body)
        if event.get("isBase64Encoded")
        else raw_body.encode()
    )

    # HMAC over the RAW bytes, constant-time compare - per GitHub docs.
    provided = headers.get("x-hub-signature-256", "")
    expected = "sha256=" + hmac.new(
        _webhook_secret().encode(), body, hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(provided, expected):
        log.warning(
            "Rejected delivery %s: bad or missing signature",
            headers.get("x-github-delivery"),
        )
        return _response(401, "invalid signature")

    gh_event = headers.get("x-github-event", "")
    if gh_event == "ping":
        return _response(200, "pong")
    if gh_event != "workflow_job":
        return _response(200, f"ignored event: {gh_event}")

    payload = json.loads(body)
    if payload.get("action") != "queued":
        return _response(200, f"ignored action: {payload.get('action')}")

    repo = ((payload.get("repository") or {}).get("full_name") or "").lower()
    if repo != ALLOWED_REPO:
        log.warning("Ignored workflow_job from unexpected repo %r", repo)
        return _response(200, "ignored repo")

    job = payload.get("workflow_job") or {}
    labels = {str(label).lower() for label in (job.get("labels") or [])}
    # GitHub assigns a job to a runner when the job's labels are a SUBSET of
    # the runner's labels - mirror exactly that rule. GitHub-hosted jobs
    # (e.g. ubuntu-latest) never match.
    if not labels or not labels.issubset(RUNNER_LABELS):
        return _response(200, "labels not ours")

    resp = _microvms.run_microvm(
        imageIdentifier=MICROVM_IMAGE_ARN,
        executionRoleArn=MICROVM_EXECUTION_ROLE_ARN,
        maximumDurationInSeconds=MICROVM_MAX_DURATION_SECONDS,
    )
    log.info(
        "Launched %s for job id=%s name=%r labels=%s (delivery %s)",
        resp.get("microvmId"),
        job.get("id"),
        job.get("name"),
        sorted(labels),
        headers.get("x-github-delivery"),
    )
    # An exception from run_microvm falls through to Lambda's error handling
    # -> Function URL returns 500 -> GitHub marks the delivery failed, which
    # is exactly what we want: visible + manually redeliverable.
    return _response(200, "microvm launched")
