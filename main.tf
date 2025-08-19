terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    auth0 = {
      source = "auth0/auth0"
    }
    aws = {
      source = "hashicorp/aws"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# =============================================================================
# CONDITIONAL DATA SOURCES - The Primary Use Case
# =============================================================================

# ❌ PROBLEMATIC: This will be evaluated during 'coder templates push'
# data "auth0_user" "workspace_owner_user" {
#   query = data.coder_workspace_owner.me.email
# }

# ✅ SOLUTION: Conditional evaluation based on workspace context
data "auth0_user" "workspace_owner_user" {
  # Only evaluate when NOT during template validation
  count = data.coder_workspace.me.name != "default" ? 1 : 0
  query = data.coder_workspace_owner.me.email
}

# ✅ SOLUTION: For templates using prebuilds, add prebuild condition
data "auth0_user" "workspace_owner_user_with_prebuild" {
  # Skip during: 1) template validation, 2) prebuild creation
  count = data.coder_workspace.me.name != "default" && data.coder_workspace.me.prebuild_count == 0 ? 1 : 0
  query = data.coder_workspace_owner.me.email
}

# External API that requires user context
data "http" "user_permissions" {
  count = data.coder_workspace.me.name != "default" ? 1 : 0
  url   = "https://api.company.com/users/${data.coder_workspace_owner.me.email}/permissions"
  
  request_headers = {
    Authorization = "Bearer ${var.api_token}"
  }
}

# Database query that should only run at workspace creation
data "external" "user_projects" {
  count   = data.coder_workspace.me.name != "default" ? 1 : 0
  program = ["python3", "${path.module}/scripts/get_user_projects.py"]
  
  query = {
    user_email = data.coder_workspace_owner.me.email
    db_host    = var.database_host
  }
}

# =============================================================================
# HARDWARE RESOURCES - Prebuild Considerations
# =============================================================================

# For hardware resources, the question is different:
# Should we create actual cloud resources during prebuilds?

# APPROACH 1: Always create resources (recommended for most cases)
# This ensures template validation catches configuration errors
resource "aws_instance" "workspace" {
  count         = data.coder_workspace.me.start_count
  ami           = "ami-0abcdef1234567890"
  instance_type = "t3.medium"
  
  # This will be created during prebuilds AND regular workspaces
  # Pro: Template validation catches errors
  # Con: Costs money during prebuild creation
  
  tags = {
    Name = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    Type = data.coder_workspace.me.prebuild_count > 0 ? "prebuild" : "workspace"
  }
}

# APPROACH 2: Skip expensive resources during prebuilds (cost optimization)
resource "aws_instance" "expensive_gpu_instance" {
  # Only create for actual workspaces, not prebuilds
  count         = data.coder_workspace.me.start_count > 0 && data.coder_workspace.me.prebuild_count == 0 ? 1 : 0
  ami           = "ami-gpu-optimized"
  instance_type = "p3.2xlarge"  # Expensive GPU instance
  
  # This saves costs during prebuild creation but reduces validation coverage
}

# APPROACH 3: Different resource sizes for prebuilds vs workspaces
locals {
  # Use smaller instances for prebuilds to save costs
  instance_type = data.coder_workspace.me.prebuild_count > 0 ? "t3.micro" : "t3.large"
  storage_size  = data.coder_workspace.me.prebuild_count > 0 ? 20 : 100
}

resource "aws_instance" "flexible_workspace" {
  count         = data.coder_workspace.me.start_count
  ami           = "ami-0abcdef1234567890"
  instance_type = local.instance_type
  
  root_block_device {
    volume_size = local.storage_size
  }
}

# =============================================================================
# USING CONDITIONAL DATA IN RESOURCES
# =============================================================================

# Kubernetes resources based on user permissions
resource "kubernetes_config_map" "user_config" {
  count = length(data.auth0_user.workspace_owner_user)
  
  metadata {
    name      = "user-permissions"
    namespace = "coder-${data.coder_workspace.me.name}"
  }
  
  data = {
    # Safe access using count-based conditional
    user_roles      = jsonencode(data.auth0_user.workspace_owner_user[0].roles)
    user_groups     = jsonencode(data.auth0_user.workspace_owner_user[0].groups)
    permissions     = length(data.http.user_permissions) > 0 ? data.http.user_permissions[0].response_body : "{}"
    assigned_projects = length(data.external.user_projects) > 0 ? jsonencode(data.external.user_projects[0].result) : "[]"
  }
}

# Environment variables for the workspace
resource "coder_agent" "main" {
  count = data.coder_workspace.me.start_count
  arch  = "amd64"
  os    = "linux"
  
  # Conditional environment variables based on user data
  env = merge(
    {
      WORKSPACE_OWNER = data.coder_workspace_owner.me.name
      WORKSPACE_NAME  = data.coder_workspace.me.name
    },
    # Only add user-specific env vars when user data is available
    length(data.auth0_user.workspace_owner_user) > 0 ? {
      USER_ROLES  = jsonencode(data.auth0_user.workspace_owner_user[0].roles)
      USER_GROUPS = jsonencode(data.auth0_user.workspace_owner_user[0].groups)
    } : {}
  )
  
  startup_script = <<-EOT
    #!/bin/bash
    set -e
    
    # Install dependencies
    curl -fsSL https://coder.com/install.sh | sh
    
    # Configure user-specific settings only if user data is available
    if [[ -n "$USER_ROLES" ]]; then
      echo "Configuring workspace for user with roles: $USER_ROLES"
      # Setup user-specific configurations
    else
      echo "Running in validation/prebuild mode - skipping user-specific setup"
    fi
  EOT
}

# =============================================================================
# VARIABLES AND OUTPUTS
# =============================================================================

variable "api_token" {
  description = "API token for external service"
  type        = string
  sensitive   = true
}

variable "database_host" {
  description = "Database host for user project queries"
  type        = string
  default     = "db.company.com"
}

# Outputs that handle conditional data gracefully
output "user_info" {
  description = "User information (only available during workspace creation)"
  value = length(data.auth0_user.workspace_owner_user) > 0 ? {
    email  = data.auth0_user.workspace_owner_user[0].email
    roles  = data.auth0_user.workspace_owner_user[0].roles
    groups = data.auth0_user.workspace_owner_user[0].groups
  } : {
    email  = "validation-mode@example.com"
    roles  = []
    groups = []
  }
}

output "execution_context" {
  description = "Information about current execution context"
  value = {
    workspace_name   = data.coder_workspace.me.name
    is_validation    = data.coder_workspace.me.name == "default"
    is_prebuild      = data.coder_workspace.me.prebuild_count > 0
    is_workspace     = data.coder_workspace.me.name != "default" && data.coder_workspace.me.prebuild_count == 0
    start_count      = data.coder_workspace.me.start_count
    prebuild_count   = data.coder_workspace.me.prebuild_count
  }
}
