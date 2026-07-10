# ---------------------------------------------------------------------------
# Latest Amazon Linux 2023 arm64 AMI via the AWS-published SSM parameter -
# no need to hardcode/refresh an AMI ID by hand.
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023_arm64_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

# ---------------------------------------------------------------------------
# Security group: no inbound by default. SSH only opens up if you explicitly
# set ssh_allowed_cidrs - otherwise use SSM Session Manager (instance profile
# below already includes AmazonSSMManagedInstanceCore).
# ---------------------------------------------------------------------------
resource "aws_security_group" "build_host" {
  name        = "${var.name_prefix}-sg"
  description = "Disposable Docker build host for the GitHub Actions MicroVM runner image"
  vpc_id      = data.aws_subnet.selected.vpc_id

  dynamic "ingress" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "SSH (opt-in - see var.ssh_allowed_cidrs)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
  }

  egress {
    description = "All outbound - needed to pull the runner tarball + pip packages, and to reach S3/SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg"
  }
}

# ---------------------------------------------------------------------------
# IAM: just enough to (a) manage the instance via SSM and (b) push the built
# artifact to the core stack's S3 bucket. Nothing else.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "build_host_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build_host" {
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.build_host_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.build_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "build_host_s3" {
  statement {
    sid       = "UploadRunnerImageArtifact"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::${var.artifact_bucket_name}/*"]
  }

  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifact_bucket_name}"]
  }
}

resource "aws_iam_role_policy" "build_host_s3" {
  name   = "${var.name_prefix}-s3-policy"
  role   = aws_iam_role.build_host.id
  policy = data.aws_iam_policy_document.build_host_s3.json
}

resource "aws_iam_instance_profile" "build_host" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.build_host.name
}

# ---------------------------------------------------------------------------
# The build host itself. Bootstraps Docker + git/zip via user_data so it's
# ready to build the moment it's reachable - no manual setup step beyond
# connecting and cloning runner-image/.
# ---------------------------------------------------------------------------
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf update -y
    dnf install -y docker git zip unzip
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOF
}

resource "aws_instance" "build_host" {
  ami                         = data.aws_ssm_parameter.al2023_arm64_ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.build_host.id]
  iam_instance_profile        = aws_iam_instance_profile.build_host.name
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name    = var.name_prefix
    Purpose = "disposable-docker-build-host-for-gh-runner-microvm-image"
  }
}
