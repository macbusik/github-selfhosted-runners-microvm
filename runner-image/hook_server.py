#!/usr/bin/env python3
"""
Lifecycle-hook supervisor for an ephemeral GitHub Actions self-hosted runner
running inside an AWS Lambda MicroVM.

Serves the AWS Lambda MicroVMs hook endpoints on HOOK_PORT (default 8080):
  - POST /aws/lambda-microvms/runtime/v1/ready       (build-time)
  - POST /aws/lambda-microvms/runtime/v1/validate    (build-time)
  - POST /aws/lambda-microvms/runtime/v1/run         (runtime: register + start)
  - POST /aws/lambda-microvms/runtime/v1/resume      (runtime: unused, see below)
  - POST /aws/lambda-microvms/runtime/v1/suspend     (runtime: unused, see below)
  - POST /aws/lambda-microvms/runtime/v1/terminate   (runtime: best-effort cleanup)

Design notes (see AWS docs "Working with snapshots" / "Lifecycle hooks" /
"MicroVM core concepts"):

  - The container's ENTRYPOINT/CMD starts *this* supervisor, not the GitHub
    runner itself. The runner is registered and launched only when /run
    fires - i.e. AFTER the MicroVM has resumed from its Firecracker
    snapshot. Registering during image *build* would bake one shared,
    already-stale registration into every MicroVM later launched from this
    image, which is exactly the "uniqueness" pitfall the docs warn about
    (all MicroVMs from one image version share identical initial state).

  - GitHub runner registration tokens expire after ~1 hour, so they can't be
    baked into the image either. We mint a fresh one on every /run via a
    GitHub App (private key pulled from Secrets Manager through the
    MicroVM's execution role) instead of a long-lived PAT.

  - The runner is configured with `--ephemeral`: GitHub deregisters it
    automatically after exactly one job. Once the runner process exits we
    additionally call terminate-microvm on ourselves, so finished runners
    never sit around accruing (or even suspended snapshot-storage) charges.
    This is why no idle-policy / suspend-resume is used for this image -
    see /resume and /suspend below.

  - If /run does not return HTTP 200, AWS docs state the MicroVM goes
    straight to TERMINATING without ever reaching RUNNING - so a failed
    registration is "free": no orphaned runner, no charges.
"""

import json
import logging
import os
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
import jwt  # PyJWT
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("runner-hooks")

HOOK_PORT = int(os.environ.get("HOOK_PORT", "8080"))
GITHUB_OWNER = os.environ["GITHUB_OWNER"]
GITHUB_REPO = os.environ["GITHUB_REPO"]
GH_APP_SECRET_ARN = os.environ["GH_APP_SECRET_ARN"]
RUNNER_LABELS = os.environ.get("RUNNER_LABELS", "self-hosted,microvm,ephemeral,linux,arm64")
RUNNER_HOME = "/home/runner/actions-runner"
GITHUB_API = "https://api.github.com"

_state_lock = threading.Lock()
_runner_process = None
_microvm_id = None


def _read_github_app_secret():
    """Fetch {"app_id", "installation_id", "private_key"} from Secrets Manager.

    Uses the MicroVM's execution role via boto3's default credential chain -
    no static credentials are ever placed in the image or in environment
    variables.
    """
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=GH_APP_SECRET_ARN)
    return json.loads(resp["SecretString"])


def _mint_installation_token(app_id, installation_id, private_key_pem):
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": str(app_id)}
    encoded_jwt = jwt.encode(payload, private_key_pem, algorithm="RS256")
    resp = requests.post(
        f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
        headers={
            "Authorization": f"Bearer {encoded_jwt}",
            "Accept": "application/vnd.github+json",
        },
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def _mint_runner_registration_token(installation_token):
    resp = requests.post(
        f"{GITHUB_API}/repos/{GITHUB_OWNER}/{GITHUB_REPO}/actions/runners/registration-token",
        headers={
            "Authorization": f"Bearer {installation_token}",
            "Accept": "application/vnd.github+json",
        },
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def _self_terminate():
    if not _microvm_id:
        log.warning("No microvmId known, skipping self-terminate call")
        return
    try:
        client = boto3.client("lambda-microvms")
        client.terminate_microvm(microvmIdentifier=_microvm_id)
        log.info("Called terminate-microvm for %s", _microvm_id)
    except Exception:
        log.exception(
            "terminate-microvm call failed - the MicroVM will still be "
            "reaped eventually by maximum-duration-in-seconds, but costs "
            "will accrue longer than necessary. Check the execution role's "
            "lambda:TerminateMicrovm permission."
        )


def _run_job_and_terminate(runner_name):
    global _runner_process
    run_sh = os.path.join(RUNNER_HOME, "run.sh")
    log.info("Starting ephemeral runner process: %s", runner_name)
    proc = subprocess.Popen([run_sh], cwd=RUNNER_HOME)
    with _state_lock:
        _runner_process = proc
    proc.wait()
    log.info("Runner process exited with code %s - job complete", proc.returncode)
    _self_terminate()


def _configure_and_launch(microvm_id, run_hook_payload):
    global _microvm_id
    _microvm_id = microvm_id
    suffix = microvm_id[-12:] if microvm_id else uuid.uuid4().hex[:12]
    runner_name = f"microvm-{suffix}"

    secret = _read_github_app_secret()
    installation_token = _mint_installation_token(
        secret["app_id"], secret["installation_id"], secret["private_key"]
    )
    reg_token = _mint_runner_registration_token(installation_token)

    config_sh = os.path.join(RUNNER_HOME, "config.sh")
    subprocess.run(
        [
            config_sh,
            "--unattended",
            "--ephemeral",
            "--replace",
            "--url", f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}",
            "--token", reg_token,
            "--name", runner_name,
            "--labels", RUNNER_LABELS,
            "--work", "_work",
        ],
        cwd=RUNNER_HOME,
        check=True,
    )

    # The job itself can run for a long time (up to the MicroVM's
    # maximum-duration-in-seconds); do this in the background so the /run
    # hook response below isn't held open for the whole job.
    threading.Thread(target=_run_job_and_terminate, args=(runner_name,), daemon=True).start()


class HookHandler(BaseHTTPRequestHandler):
    def _respond(self, status=200, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) if length else b""
        path = self.path.rstrip("/")

        try:
            if path.endswith("/ready"):
                # Build-time: the runner binary is already baked in by the
                # Dockerfile, nothing else to initialize before the snapshot
                # is taken.
                self._respond(200)

            elif path.endswith("/validate"):
                # Build-time: sanity-check the runner binary is present and
                # executable on a freshly-resumed MicroVM.
                ok = os.path.exists(os.path.join(RUNNER_HOME, "run.sh"))
                self._respond(200 if ok else 503)

            elif path.endswith("/run"):
                body = json.loads(raw_body or b"{}")
                microvm_id = body.get("microvmId")
                run_hook_payload = body.get("runHookPayload")
                log.info("Received /run for microvmId=%s payload=%r", microvm_id, run_hook_payload)
                # Registration must succeed before we return 200 - if it
                # raises, we respond 500 below and AWS tears the MicroVM
                # down without ever billing RUNNING compute for it.
                _configure_and_launch(microvm_id, run_hook_payload)
                self._respond(200)

            elif path.endswith("/resume"):
                # This image is never run with an idle-policy (ephemeral
                # runners should be terminated, not suspended), so this
                # should not normally fire. Respond 200 defensively anyway.
                log.warning("Unexpected /resume call - this image does not use suspend/resume")
                self._respond(200)

            elif path.endswith("/suspend"):
                log.warning("Unexpected /suspend call - this image does not use suspend/resume")
                self._respond(200)

            elif path.endswith("/terminate"):
                with _state_lock:
                    proc = _runner_process
                if proc and proc.poll() is None:
                    proc.terminate()
                self._respond(200)

            else:
                self._respond(404)

        except Exception:
            log.exception("Hook handler failed for path=%s", path)
            self._respond(500)

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", HOOK_PORT), HookHandler)
    log.info("Listening for AWS Lambda MicroVMs lifecycle hooks on port %s", HOOK_PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
