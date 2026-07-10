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
#
# Design decision: this image intentionally does NOT pre-bake any language
# toolchains (no Java/Node/Terraform/etc.). Workflows are expected to pull
# whatever they need from the GitHub Actions Marketplace (actions/setup-node,
# actions/setup-java, hashicorp/setup-terraform, ...) at job runtime, same as
# a GitHub-hosted runner. What's installed below is only what those
# marketplace actions themselves generally assume is already present on any
# Linux runner (git, curl/tar/unzip, a shell, sudo) - not a warmed-up build
# cache. If a specific job type ends up needing something baked in for
# startup-latency reasons, that's a deliberate follow-up, not a default.
FROM public.ecr.aws/lambda/microvms:al2023-minimal

# Check https://github.com/actions/runner/releases for the current version -
# GitHub enforces a minimum supported runner version and rotates it over
# time (>= 2.329.0 as of 2026-07).
ARG RUNNER_VERSION=2.329.0
# Lambda MicroVMs only run on ARM64 today.
ARG RUNNER_ARCH=arm64

RUN dnf install -y \
        tar gzip unzip jq git shadow-utils sudo which ca-certificates \
        python3.11 python3.11-pip libicu \
    && dnf clean all
# python3.11, NOT the default python3 (= 3.9 on AL2023): boto3 dropped
# Python 3.9 support on 2026-04-29, so under 3.9 pip silently resolves to an
# old boto3 whose service catalog predates Lambda MicroVMs (GA 2026-06-22).
# Everything then works EXCEPT boto3.client("lambda-microvms"), which dies
# with UnknownServiceError at self-terminate time - confirmed live 2026-07-10
# (job ran fine, MicroVM never terminated itself).
# libicu: the runner tarball's config.sh/run.sh wrapper scripts do a hard
# pre-check for libicu via ldconfig and exit 1 *before* ever starting the
# .NET runtime if it's missing - confirmed via live smoke test. This means
# DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 alone (see below) is not enough:
# it would tell .NET not to need ICU, but the wrapper script never gets that
# far. Keeping both: libicu satisfies the wrapper's pre-check, invariant
# mode is a harmless belt-and-suspenders in case the check ever changes.
# Deliberately NOT installing openssl-libs here: al2023-minimal already ships
# openssl-snapsafe-libs (AWS's snapshot-safe OpenSSL build, see "Working with
# snapshots" in the AWS Lambda MicroVMs docs). Explicitly requesting
# openssl-libs conflicts with it (dnf refuses the swap, which is dnf doing
# the right thing - the alternative would be silently downgrading to
# non-snapshot-safe OpenSSL). python3/pip pull in whatever OpenSSL bindings
# they need against the already-installed snapsafe version.

RUN useradd -m -d /home/runner -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner
# NOPASSWD sudo for the runner user matches GitHub-hosted runner behavior -
# marketplace actions/scripts that shell out to `sudo apt-get install ...`
# (or the dnf/yum equivalent) generally assume this without prompting.

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

# See the libicu note above - this is a defensive complement to it, not a
# substitute (a first attempt at fixing the ICU crash with just this env var
# and no libicu package still failed: the wrapper script's pre-check exits
# before .NET ever reads this variable).
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

WORKDIR /app
COPY requirements.txt .
RUN pip3.11 install --no-cache-dir -r requirements.txt \
    # Fail the image build immediately if the installed botocore doesn't know
    # the lambda-microvms service - otherwise the gap only surfaces at
    # self-terminate time, long after the build looked green.
    && python3.11 -c "import botocore.session; botocore.session.get_session().get_service_model('lambda-microvms')"

COPY hook_server.py .
RUN chown -R runner:runner /home/runner/actions-runner /app

USER runner
ENV HOME=/home/runner
EXPOSE 8080

# The container's job is to supervise AWS lifecycle hooks, not to run the
# GitHub runner directly - see hook_server.py for why (registration has to
# happen after resume-from-snapshot, not during image build).
CMD ["python3.11", "/app/hook_server.py"]
