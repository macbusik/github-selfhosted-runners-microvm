#!/usr/bin/env bash
# Builds dispatcher.zip - the Lambda deployment package referenced by
# terraform/dispatcher.tf. Run this before `terraform apply` whenever
# handler.py or requirements.txt change (Terraform picks up the new zip via
# filebase64sha256 and updates the function code in place).
#
# boto3/botocore are pure Python, so building on any OS/arch works for the
# arm64 Lambda - no docker/QEMU needed here, unlike the runner image.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build dispatcher.zip
python3 -m pip install --quiet --target build -r requirements.txt

# Same guard as the runner image's Dockerfile: a botocore that doesn't know
# lambda-microvms must fail HERE, not at the first webhook delivery.
python3 - <<'EOF'
import sys
sys.path.insert(0, "build")
import botocore.session
botocore.session.get_session().get_service_model("lambda-microvms")
print("botocore OK - zna lambda-microvms")
EOF

cp handler.py build/
(cd build && zip -qr -X ../dispatcher.zip .)
echo "OK: $(pwd)/dispatcher.zip ($(du -h dispatcher.zip | cut -f1))"
