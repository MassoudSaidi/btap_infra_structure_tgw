# This is a Terragrunt helper function. It finds the root of the Git repo,
# which is a reliable way to find the root of the project.
locals {
  project_root = get_repo_root()
}

# This block tells Terragrunt to generate a provider.tf file inside the .terragrunt-cache.
# This is the modern, recommended way to configure providers with Terragrunt.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region                   = "ca-central-1"
  profile                  = "dev"

  # Explicitly tell the provider where to find the config files using an absolute path.
  # This makes the configuration completely independent of the shell environment.
  shared_config_files      = ["${local.project_root}/.aws/config"]
  shared_credentials_files = ["${local.project_root}/.aws/credentials"]
}
EOF
}

inputs = {
  surrogate_workload_vpc_id = "vpc-0c095736cf65241cb"  # "vpc-0809102c90503ef2d"  # From client's info; confirm if needed
}