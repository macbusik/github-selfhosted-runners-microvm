# syntax=docker/dockerfile:1
#
# GitHub Actions self-hosted runner image for AWS Lambda MicroVMs.
#
# This Dockerfile + hook_server.py + requirements.txt is what gets zipped and
# uploaded to S3 - Lambda itself runs this Dockerfile on its own build
# infrastructure when you call create-microvm-image. Building it here with
# `docker build`/`docker run` first (e.g. on a disposable EC2 box) is just to
# test it before trusting it to that pipeline; Docker is not required to
# produce or upload the zip artifact itself.
#
# Base: Lambda's own Amazon Linux 2023 minimal image. Required for
# snapshot-safe OpenSSL - see "Working with snapshots" / snapshot-compatible
# base images in the AWS Lambda MicroVMs docs.
FROM public.ecr.aws/lambda/microvms:al2023-minimal

# Check https://github.com/actions/runner/releases for the current version -
# GitHub enforces a minimum supported runner version and rotates it over
# time (>= 2.329.0 as of 2026-07).
ARG RUNNER_VERSION=2.329.0
# Lambda MicroVMs only run on ARM64 today.
ARG RUNNER_ARCH=arm64

RUN dnf install -y \
        tar gzip curl jq git shadow-utils sudo \
        python3 python3-pip openssl-libs \
    && dnf clean all

RUN useradd -m -d /home/runner -s /bin/bash runner

RUN mkdir -p /home/runner/actions-runner \
    && cd /home/runner/actions-runner \
    && curl -fsSL -o actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && tar xzf actions-runner.tar.gz \
    && rm actions-runner.tar.gz \
    && (./bin/installdependencies.sh || true)
# installdependencies.sh mainly targets apt-based distros; on AL2023 it may
# no-op or fail harmlessly since the packages it wants are already covered
# above via dnf. Verify the runner actually starts correctly when you smoke
# test this image on the EC2 build box - see ../README.md.

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

COPY hook_server.py .
RUN chown -R runner:runner /home/runner/actions-runner /app

USER runner
ENV HOME=/home/runner
EXPOSE 8080

# The container's job is to supervise AWS lifecycle hooks, not to run the
# GitHub runner directly - see hook_server.py for why (registration has to
# happen after resume-from-snapshot, not during image build).
CMD ["python3", "/app/hook_server.py"]
