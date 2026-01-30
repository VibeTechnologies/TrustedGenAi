# ==============================================================================
# TrustedGenAi - TEE Infrastructure for LLM Inference
# ==============================================================================
#
# Deploys LLM inference infrastructure on Trusted Execution Environment (TEE)
# hardware with cryptographic attestation.
#
# Supported configurations:
#   - CPU TEE: Intel TDX on Azure DCesv5 series (DeepSeek via Ollama)
#   - GPU TEE: AMD SEV-SNP + NVIDIA CC on Azure NCCads_H100_v5 (DeepSeek via vLLM)
#
# Usage:
#   terraform init
#   terraform plan -var="enable_cpu_tee=true"
#   terraform apply -var="enable_cpu_tee=true"
#
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}

# ==============================================================================
# Variables
# ==============================================================================

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "trustedgenai-rg"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus2"
}

variable "enable_cpu_tee" {
  description = "Enable CPU TEE deployment (Intel TDX)"
  type        = bool
  default     = false
}

variable "enable_gpu_tee" {
  description = "Enable GPU TEE deployment (NVIDIA H100 CC)"
  type        = bool
  default     = false
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VM access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "tee_api_key" {
  description = "API key for TEE LiteLLM endpoint"
  type        = string
  default     = "sk-tee-deepseek-key"
  sensitive   = true
}

# ==============================================================================
# Resource Group
# ==============================================================================

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project     = "TrustedGenAi"
    environment = "production"
  }
}

# Data source for compatibility with existing terraform files
data "azurerm_resource_group" "vibe" {
  name = azurerm_resource_group.main.name

  depends_on = [azurerm_resource_group.main]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region"
  value       = azurerm_resource_group.main.location
}
