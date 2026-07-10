# Skopiuj do terraform.tfvars (gitignored) i uzupełnij.

# Z outputu ../terraform: `terraform output -raw artifact_bucket`
artifact_bucket_name = "gh-runner-microvm-artifacts-123456789012-us-east-1"

# Musisz podać istniejący subnet - żadnego domyślnego VPC/subnetu w tle.
subnet_id = "subnet-xxxxxxxxxxxxxxxxx"

# Opcjonalne - patrz variables.tf:
# aws_region           = "us-east-1"
# instance_type        = "t4g.small"
# ssh_allowed_cidrs    = ["203.0.113.4/32"]   # puste = tylko SSM Session Manager
# key_name             = "my-keypair"
# associate_public_ip  = true
# name_prefix          = "gh-runner-microvm-build-host"
