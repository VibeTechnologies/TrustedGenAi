# ==============================================================================
# DeepSeek TEE POC - Minimal Confidential VM for CPU Inference
# ==============================================================================
#
# This deploys a minimal Azure Confidential VM (DCasv5) running DeepSeek via ollama.
# Purpose: Prove DeepSeek works in TEE at lowest cost before scaling up.
#
# Hardware: Standard_DC8as_v5 (8 vCPU, 32GB RAM) ~$0.40/hr
# Model: deepseek-r1:7b (4.7GB, runs in ~8GB RAM)
# Technology: AMD SEV-SNP (hardware memory encryption)
#
# Enable: terraform apply -var="enable_deepseek_tee_poc=true"
# Test: curl http://<ip>:11434/api/generate -d '{"model":"deepseek-r1:7b","prompt":"Hello"}'
#
# Related: research/tee-deepseek/todo.md
# ==============================================================================

variable "enable_deepseek_tee_poc" {
  description = "Enable DeepSeek TEE POC deployment"
  type        = bool
  default     = false
}

variable "deepseek_tee_location" {
  description = "Azure region for VM"
  type        = string
  default     = "centralus" # Trying centralus - westus3 also has capacity issues
}

variable "deepseek_tee_vm_size" {
  description = "VM size for DeepSeek POC"
  type        = string
  default     = "Standard_B4ms" # 4 vCPU, 16GB RAM, ~$0.17/hr - trying smaller for availability

  validation {
    condition = contains([
      # B-series burstable - typically better availability
      "Standard_B4ms",  # 4 vCPU, 16GB  ~$0.17/hr
      "Standard_B8ms",  # 8 vCPU, 32GB  ~$0.33/hr - recommended for 7B
      "Standard_B16ms", # 16 vCPU, 64GB ~$0.67/hr - for 14B model
      "Standard_B20ms", # 20 vCPU, 80GB ~$0.83/hr
      # Intel D-series v5 (backup)
      "Standard_D4s_v5",  # 4 vCPU, 16GB  ~$0.19/hr
      "Standard_D8s_v5",  # 8 vCPU, 32GB  ~$0.38/hr
      "Standard_D16s_v5", # 16 vCPU, 64GB ~$0.77/hr
      "Standard_D32s_v5", # 32 vCPU, 128GB ~$1.54/hr
      # AMD D-series v5 (backup)
      "Standard_D4as_v5",  # 4 vCPU, 16GB  ~$0.17/hr
      "Standard_D8as_v5",  # 8 vCPU, 32GB  ~$0.35/hr
      "Standard_D16as_v5", # 16 vCPU, 64GB ~$0.70/hr
      "Standard_D32as_v5", # 32 vCPU, 128GB ~$1.40/hr
    ], var.deepseek_tee_vm_size)
    error_message = "VM size must be a supported VM type"
  }
}

variable "deepseek_tee_model" {
  description = "DeepSeek model to run via ollama"
  type        = string
  default     = "deepseek-r1:1.5b" # 1.1GB model, fits in 16GB RAM (B4ms)

  validation {
    condition = contains([
      "deepseek-r1:1.5b", # 1.1GB - very fast, low quality
      "deepseek-r1:7b",   # 4.7GB - good balance for POC
      "deepseek-r1:8b",   # 5.2GB - latest 8B version
      "deepseek-r1:14b",  # 9.0GB - needs 32GB+ RAM
      "deepseek-r1:32b",  # 20GB  - needs 64GB+ RAM
    ], var.deepseek_tee_model)
    error_message = "Must be a supported DeepSeek ollama model"
  }
}

# ==============================================================================
# Network Infrastructure
# ==============================================================================

resource "azurerm_virtual_network" "deepseek_tee" {
  count               = var.enable_deepseek_tee_poc ? 1 : 0
  name                = "vibe-deepseek-tee-vnet"
  location            = var.deepseek_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  address_space       = ["10.2.0.0/16"]

  tags = {
    purpose = "deepseek-tee-poc"
  }
}

resource "azurerm_subnet" "deepseek_tee" {
  count                = var.enable_deepseek_tee_poc ? 1 : 0
  name                 = "tee-subnet"
  resource_group_name  = data.azurerm_resource_group.vibe.name
  virtual_network_name = azurerm_virtual_network.deepseek_tee[0].name
  address_prefixes     = ["10.2.0.0/24"]
}

resource "azurerm_network_security_group" "deepseek_tee" {
  count               = var.enable_deepseek_tee_poc ? 1 : 0
  name                = "vibe-deepseek-tee-nsg"
  location            = var.deepseek_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  # SSH for management
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

  # Ollama API port
  security_rule {
    name                       = "Ollama-API"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "11434"
    source_address_prefix      = "10.0.0.0/8" # Internal only
    destination_address_prefix = "*"
  }

  tags = {
    purpose = "deepseek-tee-poc"
  }
}

resource "azurerm_subnet_network_security_group_association" "deepseek_tee" {
  count                     = var.enable_deepseek_tee_poc ? 1 : 0
  subnet_id                 = azurerm_subnet.deepseek_tee[0].id
  network_security_group_id = azurerm_network_security_group.deepseek_tee[0].id
}

# ==============================================================================
# Public IP for Testing (remove in production)
# ==============================================================================

resource "azurerm_public_ip" "deepseek_tee" {
  count               = var.enable_deepseek_tee_poc ? 1 : 0
  name                = "vibe-deepseek-tee-pip"
  location            = var.deepseek_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    purpose = "deepseek-tee-poc"
  }
}

resource "azurerm_network_interface" "deepseek_tee" {
  count               = var.enable_deepseek_tee_poc ? 1 : 0
  name                = "vibe-deepseek-tee-nic"
  location            = var.deepseek_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.deepseek_tee[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.deepseek_tee[0].id
  }

  tags = {
    purpose = "deepseek-tee-poc"
  }
}

# ==============================================================================
# Confidential VM with AMD SEV-SNP
# ==============================================================================

resource "azurerm_linux_virtual_machine" "deepseek_tee" {
  count               = var.enable_deepseek_tee_poc ? 1 : 0
  name                = "vibe-deepseek-tee-vm"
  resource_group_name = data.azurerm_resource_group.vibe.name
  location            = var.deepseek_tee_location
  size                = var.deepseek_tee_vm_size
  admin_username      = "azureuser"
  # Removed zone constraint for better availability across regions

  # TrustedLaunch settings (vTPM + SecureBoot)
  # Note: Full Confidential VM (security_type=ConfidentialVM) requires azurerm 4.x
  vtpm_enabled        = true
  secure_boot_enabled = true

  network_interface_ids = [
    azurerm_network_interface.deepseek_tee[0].id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  # Ubuntu 22.04 LTS
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  # Install ollama and pull DeepSeek model
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    # Set HOME for root user (cloud-init runs as root)
    export HOME=/root
    
    # Log to file for debugging
    exec > /var/log/deepseek-init.log 2>&1
    
    echo "=== DeepSeek TEE POC Setup ==="
    echo "VM Size: ${var.deepseek_tee_vm_size}"
    echo "Model: ${var.deepseek_tee_model}"
    date
    
    # Install ollama
    echo "Installing ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Enable and start ollama service
    systemctl enable ollama
    systemctl start ollama
    
    # Wait for ollama to be ready
    sleep 10
    
    # Pull the DeepSeek model (set HOME for ollama CLI)
    echo "Pulling model: ${var.deepseek_tee_model}"
    HOME=/root ollama pull ${var.deepseek_tee_model}
    
    # Configure ollama to listen on all interfaces (for LiteLLM proxy)
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/override.conf <<'OVERRIDE'
    [Service]
    Environment="OLLAMA_HOST=0.0.0.0"
    OVERRIDE
    
    systemctl daemon-reload
    systemctl restart ollama
    
    # Verify installation
    echo "Testing model..."
    sleep 5
    HOME=/root ollama run ${var.deepseek_tee_model} "Hello, are you running in a TEE?" --verbose
    
    echo "=== Setup Complete ==="
    date
    
    # Create health check endpoint info
    cat > /home/azureuser/README.md <<'README'
    # DeepSeek TEE POC
    
    ## Test the model
    curl http://localhost:11434/api/generate -d '{
      "model": "${var.deepseek_tee_model}",
      "prompt": "What is a Trusted Execution Environment?",
      "stream": false
    }'
    
    ## Check ollama status
    systemctl status ollama
    
    ## View logs
    journalctl -u ollama -f
    
    ## TEE Attestation (verify AMD SEV-SNP)
    dmesg | grep -i sev
    cat /sys/kernel/debug/sev/sev_status 2>/dev/null || echo "SEV status not available"
    README
    
    chown azureuser:azureuser /home/azureuser/README.md
  EOF
  )

  tags = {
    purpose     = "deepseek-tee-poc"
    model       = var.deepseek_tee_model
    tee_enabled = "true"
    tee_type    = "AMD-SEV-SNP"
  }
}

# ==============================================================================
# Outputs
# ==============================================================================

output "deepseek_tee_poc_enabled" {
  description = "Whether DeepSeek TEE POC is enabled"
  value       = var.enable_deepseek_tee_poc
}

output "deepseek_tee_public_ip" {
  description = "Public IP for SSH access"
  value       = var.enable_deepseek_tee_poc ? azurerm_public_ip.deepseek_tee[0].ip_address : null
}

output "deepseek_tee_ssh_command" {
  description = "SSH command to access the VM"
  value       = var.enable_deepseek_tee_poc ? "ssh azureuser@${azurerm_public_ip.deepseek_tee[0].ip_address}" : null
}

output "deepseek_tee_ollama_endpoint" {
  description = "Ollama API endpoint (internal only)"
  value       = var.enable_deepseek_tee_poc ? "http://${azurerm_network_interface.deepseek_tee[0].private_ip_address}:11434" : null
}

output "deepseek_tee_estimated_cost" {
  description = "Estimated hourly cost"
  value = var.enable_deepseek_tee_poc ? format("~$%.2f/hr for %s running %s",
    var.deepseek_tee_vm_size == "Standard_D4as_v5" ? 0.17 :
    var.deepseek_tee_vm_size == "Standard_D8as_v5" ? 0.35 :
    var.deepseek_tee_vm_size == "Standard_D16as_v5" ? 0.70 :
    var.deepseek_tee_vm_size == "Standard_D32as_v5" ? 1.40 : 0.0,
    var.deepseek_tee_vm_size,
    var.deepseek_tee_model
  ) : null
}

output "deepseek_tee_test_command" {
  description = "Command to test the DeepSeek model"
  value       = var.enable_deepseek_tee_poc ? "curl http://localhost:11434/api/generate -d '{\"model\":\"${var.deepseek_tee_model}\",\"prompt\":\"Hello from TEE!\",\"stream\":false}'" : null
}
