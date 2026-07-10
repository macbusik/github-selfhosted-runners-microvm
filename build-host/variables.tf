variable "aws_region" {
  description = "Region to launch the build host in. Should match the region used for the core stack in ../terraform (same account, same S3 artifact bucket)."
  type        = string
  default     = "us-east-1"
}

variable "artifact_bucket_name" {
  description = "Name of the S3 bucket from the core stack (../terraform output `artifact_bucket`) that the build host uploads gh-runner-image.zip to. Passed explicitly rather than read via terraform_remote_state - see README for why."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the build host into. Required, no default/no default-VPC fallback - deliberately explicit rather than implicit (this project assumes accounts that may not even have a default VPC)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must be ARM64 (Graviton) to match Lambda MicroVMs' architecture and build the container natively, without QEMU emulation."
  type        = string
  default     = "t4g.small"
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into the build host on port 22. Empty by default - the instance profile already includes AmazonSSMManagedInstanceCore, so `aws ssm start-session` works without opening any inbound port or managing a key pair. Only set this if you specifically want SSH."
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access. Leave null to rely solely on SSM Session Manager (default/recommended)."
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Whether the build host gets a public IP. Needed today because the build pulls the GitHub Actions runner tarball and pip packages directly from the public internet, and (if no VPC endpoints exist) SSM needs a path out too. Set to false once egress goes through a private artifactory/NAT + VPC endpoints - see README roadmap."
  type        = bool
  default     = true
}

variable "name_prefix" {
  type    = string
  default = "gh-runner-microvm-build-host"
}
