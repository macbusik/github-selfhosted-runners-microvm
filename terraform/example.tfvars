# Skopiuj do terraform.tfvars (gitignored) i uzupełnij swoimi wartościami.
github_owner = "your-github-org-or-user"
github_repo  = "your-repo"

# Required - no sane default exists (AWS rejects an empty string). Look it up
# with:
#   aws lambda-microvms list-managed-microvm-image-versions \
#     --image-identifier arn:aws:lambda:<region>:aws:microvm-image:al2023-1
# Use the NORMALIZED form ("0.0", not "0") - the API stores "0" as "0.0" and a
# mismatch shows up as a replacement-forcing diff after terraform import.
base_image_version = "0.0"

# Optional - patrz variables.tf dla pełnej listy i wartości domyślnych.
# github_app_secret_name: nadpisanie nazwy sekretu - TYLKO do przypięcia już
# istniejącego sekretu o nazwie niezgodnej z wzorcem (zmiana nazwy sekretu to
# destroy+create = utrata credentiali). Patrz variables.tf.
# github_app_secret_name           = null
# aws_region: jako 2026-07 tylko us-east-1 ma w pełni wystawione control-plane
# API (CLI/SDK/Terraform) dla Lambda MicroVMs - eu-west-1 pokazuje zasoby w
# konsoli, ale odrzuca wywołania API. Sprawdź stan przed zmianą.
# aws_region                       = "us-east-1"
# name_prefix                      = "gh-runner-microvm"
# runner_labels                    = "self-hosted,microvm,ephemeral,linux,arm64"
# runner_image_baseline_memory_mib = 2048
