# ==============================================================================
# Self-Hosted DeepSeek-V3 on Azure GPU VMs
# ==============================================================================
#
# This module deploys DeepSeek-V3 on Azure GPU VMs using SGLang.
# Enable by setting: enable_deepseek_gpu = true
#
# Hardware configurations (from SGLang benchmarks):
# - FP8:  8x H100 (1 node) or 2x 8x H20 (2 nodes)
# - BF16: 4x 8x A100 (32 GPUs total)
# - INT8: 2x 8x A100 (16 GPUs total) - recommended for testing
#
# Cost estimates (pay-as-you-go):
# - ND96amsr_A100_v4 (8x A100 80GB): ~$27.20/hr
# - 2 nodes for INT8: ~$54.40/hr
# - Spot VMs can reduce cost by 60-90%
#
# Related: Issue #408
# ==============================================================================

variable "enable_deepseek_gpu" {
  description = "Enable self-hosted DeepSeek-V3 GPU deployment"
  type        = bool
  default     = false
}

variable "deepseek_gpu_location" {
  description = "Azure region for GPU VMs (must have A100/H100 availability)"
  type        = string
  default     = "eastus2"
}

variable "deepseek_vm_size" {
  description = "VM size for DeepSeek deployment"
  type        = string
  default     = "Standard_ND96amsr_A100_v4" # 8x A100 80GB

  validation {
    condition = contains([
      "Standard_ND96amsr_A100_v4", # 8x A100 80GB (~$27.20/hr)
      "Standard_NC96ads_A100_v4",  # 4x A100 80GB (~$13.60/hr)
      "Standard_NC40ads_H100_v5",  # 1x H100 80GB (~$3.67/hr)
    ], var.deepseek_vm_size)
    error_message = "VM size must be an A100 or H100 series"
  }
}

variable "deepseek_node_count" {
  description = "Number of GPU nodes (2 for INT8, 4 for BF16)"
  type        = number
  default     = 2

  validation {
    condition     = var.deepseek_node_count >= 1 && var.deepseek_node_count <= 8
    error_message = "Node count must be between 1 and 8"
  }
}

variable "deepseek_use_spot" {
  description = "Use Spot VMs for cost savings (may be preempted)"
  type        = bool
  default     = true
}

variable "deepseek_model" {
  description = "DeepSeek model to deploy"
  type        = string
  default     = "meituan/DeepSeek-R1-Block-INT8" # INT8 quantized for 16 GPUs

  validation {
    condition = contains([
      "deepseek-ai/DeepSeek-V3",               # FP8, needs 8x H100/H200
      "meituan/DeepSeek-R1-Block-INT8",        # INT8, needs 16x A100
      "meituan/DeepSeek-R1-Channel-INT8",      # INT8, needs 16x A100
      "novita/Deepseek-V3-0324-W4AFP8",        # W4FP8, needs 4x H200
      "cognitivecomputations/DeepSeek-R1-AWQ", # AWQ, needs 8x A100
    ], var.deepseek_model)
    error_message = "Must be a supported DeepSeek model variant"
  }
}

variable "deepseek_enable_tee" {
  description = "Enable Trusted Execution Environment (Confidential VM)"
  type        = bool
  default     = false
}

# ==============================================================================
# Virtual Network for GPU Cluster
# ==============================================================================

resource "azurerm_virtual_network" "deepseek" {
  count               = var.enable_deepseek_gpu ? 1 : 0
  name                = "vibe-deepseek-vnet"
  location            = var.deepseek_gpu_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  address_space       = ["10.1.0.0/16"]

  tags = {
    purpose = "deepseek-gpu-cluster"
  }
}

resource "azurerm_subnet" "deepseek" {
  count                = var.enable_deepseek_gpu ? 1 : 0
  name                 = "gpu-subnet"
  resource_group_name  = data.azurerm_resource_group.vibe.name
  virtual_network_name = azurerm_virtual_network.deepseek[0].name
  address_prefixes     = ["10.1.0.0/24"]
}

# ==============================================================================
# Network Security Group
# ==============================================================================

resource "azurerm_network_security_group" "deepseek" {
  count               = var.enable_deepseek_gpu ? 1 : 0
  name                = "vibe-deepseek-nsg"
  location            = var.deepseek_gpu_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  # Allow SSH for management
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*" # TODO: Restrict to admin IPs
    destination_address_prefix = "*"
  }

  # Allow SGLang API port
  security_rule {
    name                       = "SGLang-API"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000"
    source_address_prefix      = "10.0.0.0/8" # Internal only
    destination_address_prefix = "*"
  }

  # Allow NCCL communication between nodes
  security_rule {
    name                       = "NCCL"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "5000-6000"
    source_address_prefix      = "10.1.0.0/24"
    destination_address_prefix = "*"
  }

  tags = {
    purpose = "deepseek-gpu-cluster"
  }
}

resource "azurerm_subnet_network_security_group_association" "deepseek" {
  count                     = var.enable_deepseek_gpu ? 1 : 0
  subnet_id                 = azurerm_subnet.deepseek[0].id
  network_security_group_id = azurerm_network_security_group.deepseek[0].id
}

# ==============================================================================
# Storage Account for Model Weights
# ==============================================================================

resource "azurerm_storage_account" "deepseek" {
  count                    = var.enable_deepseek_gpu ? 1 : 0
  name                     = "vibedeepseekmodels"
  resource_group_name      = data.azurerm_resource_group.vibe.name
  location                 = var.deepseek_gpu_location
  account_tier             = "Premium"
  account_replication_type = "LRS"
  account_kind             = "FileStorage"

  tags = {
    purpose = "deepseek-model-weights"
  }
}

resource "azurerm_storage_share" "models" {
  count                = var.enable_deepseek_gpu ? 1 : 0
  name                 = "models"
  storage_account_name = azurerm_storage_account.deepseek[0].name
  quota                = 2048 # 2TB for model weights

  depends_on = [azurerm_storage_account.deepseek]
}

# ==============================================================================
# GPU Virtual Machine Scale Set
# ==============================================================================

resource "azurerm_linux_virtual_machine_scale_set" "deepseek" {
  count               = var.enable_deepseek_gpu ? 1 : 0
  name                = "vibe-deepseek-vmss"
  resource_group_name = data.azurerm_resource_group.vibe.name
  location            = var.deepseek_gpu_location
  sku                 = var.deepseek_vm_size
  instances           = var.deepseek_node_count
  admin_username      = "azureuser"
  priority            = var.deepseek_use_spot ? "Spot" : "Regular"
  eviction_policy     = var.deepseek_use_spot ? "Deallocate" : null
  max_bid_price       = var.deepseek_use_spot ? -1 : null # Pay up to on-demand price

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  source_image_reference {
    publisher = "microsoft-dsvm"
    offer     = "ubuntu-hpc"
    sku       = "2204"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 512
  }

  network_interface {
    name                          = "nic"
    primary                       = true
    enable_accelerated_networking = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.deepseek[0].id
    }
  }

  # Custom data to bootstrap SGLang
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    # Install Docker
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker azureuser
    
    # Install NVIDIA Container Toolkit
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update && apt-get install -y nvidia-container-toolkit
    systemctl restart docker
    
    # Pull SGLang image
    docker pull lmsysorg/sglang:latest
    
    # Create systemd service for SGLang
    cat > /etc/systemd/system/sglang.service <<'SERVICE'
    [Unit]
    Description=SGLang DeepSeek Server
    After=docker.service
    Requires=docker.service
    
    [Service]
    Type=simple
    Restart=always
    RestartSec=10
    ExecStartPre=-/usr/bin/docker stop sglang
    ExecStartPre=-/usr/bin/docker rm sglang
    ExecStart=/usr/bin/docker run --gpus all --shm-size 32g \
      --network=host --ipc=host --privileged \
      -v /mnt/models:/root/.cache/huggingface \
      --name sglang \
      lmsysorg/sglang:latest \
      python3 -m sglang.launch_server \
        --model ${var.deepseek_model} \
        --tp 8 \
        --trust-remote-code \
        --port 30000 \
        --enable-torch-compile \
        --torch-compile-max-bs 8
    ExecStop=/usr/bin/docker stop sglang
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    systemctl daemon-reload
    systemctl enable sglang
    
    echo "DeepSeek GPU node initialized" > /var/log/deepseek-init.log
  EOF
  )

  tags = {
    purpose     = "deepseek-gpu-cluster"
    model       = var.deepseek_model
    tee_enabled = var.deepseek_enable_tee
  }

  lifecycle {
    ignore_changes = [instances]
  }
}

# ==============================================================================
# Load Balancer for SGLang API
# ==============================================================================

resource "azurerm_public_ip" "deepseek_lb" {
  count               = var.enable_deepseek_gpu ? 1 : 0
  name                = "vibe-deepseek-lb-ip"
  location            = var.deepseek_gpu_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    purpose = "deepseek-api-lb"
  }
}

resource "azurerm_lb" "deepseek" {
  count               = var.enable_deepseek_gpu ? 1 : 0
  name                = "vibe-deepseek-lb"
  location            = var.deepseek_gpu_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.deepseek_lb[0].id
  }

  tags = {
    purpose = "deepseek-api-lb"
  }
}

resource "azurerm_lb_backend_address_pool" "deepseek" {
  count           = var.enable_deepseek_gpu ? 1 : 0
  loadbalancer_id = azurerm_lb.deepseek[0].id
  name            = "sglang-pool"
}

resource "azurerm_lb_probe" "sglang" {
  count           = var.enable_deepseek_gpu ? 1 : 0
  loadbalancer_id = azurerm_lb.deepseek[0].id
  name            = "sglang-health"
  port            = 30000
  protocol        = "Http"
  request_path    = "/health"
}

resource "azurerm_lb_rule" "sglang" {
  count                          = var.enable_deepseek_gpu ? 1 : 0
  loadbalancer_id                = azurerm_lb.deepseek[0].id
  name                           = "SGLang-API"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 30000
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.deepseek[0].id]
  probe_id                       = azurerm_lb_probe.sglang[0].id
}

# ==============================================================================
# Outputs
# ==============================================================================

output "deepseek_gpu_enabled" {
  description = "Whether DeepSeek GPU deployment is enabled"
  value       = var.enable_deepseek_gpu
}

output "deepseek_api_endpoint" {
  description = "DeepSeek API endpoint URL"
  value       = var.enable_deepseek_gpu ? "https://${azurerm_public_ip.deepseek_lb[0].ip_address}:443" : null
}

output "deepseek_estimated_hourly_cost" {
  description = "Estimated hourly cost for the GPU cluster"
  value = var.enable_deepseek_gpu ? format("$%.2f/hr (%s)",
    var.deepseek_use_spot ? var.deepseek_node_count * 10.0 : var.deepseek_node_count * 27.20,
    var.deepseek_use_spot ? "Spot pricing" : "Pay-as-you-go"
  ) : null
}
