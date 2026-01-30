# ==============================================================================
# DeepSeek TRUE Confidential VM - Intel TDX or AMD SEV-SNP TEE
# ==============================================================================
#
# This uses azapi provider to deploy a true Confidential VM since azurerm 3.x
# does not support security_type = "ConfidentialVM".
#
# Hardware Options:
#   - DC4es_v5 (Intel TDX): 4 vCPU, 16GB RAM, ~$0.30/hr
#   - DC4as_v5 (AMD SEV-SNP): 4 vCPU, 16GB RAM, ~$0.20/hr
#
# Model: deepseek-r1:1.5b (1.1GB, fastest inference on CPU)
# Current Deployment: DC4es_v5 with Intel TDX (verified)
#
# Enable: terraform apply -var="enable_deepseek_confidential=true"
#
# Verify TEE: 
#   Intel TDX: ssh azureuser@<ip> "dmesg | grep -i tdx"
#   AMD SEV:   ssh azureuser@<ip> "dmesg | grep -i sev"
# ==============================================================================

variable "enable_deepseek_confidential" {
  description = "Enable DeepSeek Confidential VM (true TEE) deployment"
  type        = bool
  default     = false
}

variable "deepseek_confidential_location" {
  description = "Azure region for Confidential VM"
  type        = string
  default     = "eastus2" # Has DC-series availability
}

variable "deepseek_confidential_vm_size" {
  description = "VM size - must be DCasv5 (AMD SEV-SNP) or DCesv5 (Intel TDX) series for TEE"
  type        = string
  default     = "Standard_DC4es_v5" # 4 vCPU, 16GB RAM, Intel TDX, ~$0.30/hr

  validation {
    condition     = can(regex("^Standard_DC[0-9]+[ae]s_v5$", var.deepseek_confidential_vm_size))
    error_message = "Must be DCasv5 or DCesv5 series for Confidential VM support"
  }
}

variable "deepseek_confidential_model" {
  description = "DeepSeek model to run via ollama"
  type        = string
  default     = "deepseek-r1:1.5b" # 1.1GB model, ~12 tok/s on CPU
}

# ==============================================================================
# Network Infrastructure for Confidential VM
# ==============================================================================

resource "azurerm_virtual_network" "deepseek_confidential" {
  count               = var.enable_deepseek_confidential ? 1 : 0
  name                = "vibe-deepseek-cvm-vnet"
  location            = var.deepseek_confidential_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  address_space       = ["10.3.0.0/16"]

  tags = {
    purpose = "deepseek-confidential-vm"
  }
}

resource "azurerm_subnet" "deepseek_confidential" {
  count                = var.enable_deepseek_confidential ? 1 : 0
  name                 = "cvm-subnet"
  resource_group_name  = data.azurerm_resource_group.vibe.name
  virtual_network_name = azurerm_virtual_network.deepseek_confidential[0].name
  address_prefixes     = ["10.3.0.0/24"]
}

resource "azurerm_network_security_group" "deepseek_confidential" {
  count               = var.enable_deepseek_confidential ? 1 : 0
  name                = "vibe-deepseek-cvm-nsg"
  location            = var.deepseek_confidential_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Ollama-API"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "11434"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "LiteLLM-API"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Attestation-API"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4001"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 1005
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 1006
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    purpose = "deepseek-confidential-vm"
  }
}

resource "azurerm_subnet_network_security_group_association" "deepseek_confidential" {
  count                     = var.enable_deepseek_confidential ? 1 : 0
  subnet_id                 = azurerm_subnet.deepseek_confidential[0].id
  network_security_group_id = azurerm_network_security_group.deepseek_confidential[0].id
}

resource "azurerm_public_ip" "deepseek_confidential" {
  count               = var.enable_deepseek_confidential ? 1 : 0
  name                = "vibe-deepseek-cvm-pip"
  location            = var.deepseek_confidential_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    purpose = "deepseek-confidential-vm"
  }
}

resource "azurerm_network_interface" "deepseek_confidential" {
  count               = var.enable_deepseek_confidential ? 1 : 0
  name                = "vibe-deepseek-cvm-nic"
  location            = var.deepseek_confidential_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.deepseek_confidential[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.deepseek_confidential[0].id
  }

  tags = {
    purpose = "deepseek-confidential-vm"
  }
}

# ==============================================================================
# Confidential VM using azapi provider (azurerm 3.x doesn't support CVM)
# ==============================================================================

# Cloud-init script for DeepSeek setup
locals {
  deepseek_confidential_cloud_init = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    export HOME=/root
    exec > /var/log/deepseek-init.log 2>&1
    
    echo "=== DeepSeek Confidential VM Setup ==="
    echo "VM Size: ${var.deepseek_confidential_vm_size}"
    echo "Model: ${var.deepseek_confidential_model}"
    date
    
    # Verify TEE is active (Intel TDX for DCesv5, AMD SEV for DCasv5)
    echo "Checking TEE status..."
    dmesg | grep -iE 'sev|tdx|memory encryption' || echo "TEE messages not found in dmesg"
    
    # Install ollama
    echo "Installing ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    systemctl enable ollama
    systemctl start ollama
    sleep 10
    
    # Pull DeepSeek model
    echo "Pulling model: ${var.deepseek_confidential_model}"
    HOME=/root ollama pull ${var.deepseek_confidential_model}
    
    # Configure ollama for LiteLLM
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/override.conf <<'OVERRIDE'
    [Service]
    Environment="OLLAMA_HOST=0.0.0.0"
    OVERRIDE
    
    systemctl daemon-reload
    systemctl restart ollama
    
    # Install LiteLLM
    echo "Installing LiteLLM..."
    apt-get update -qq
    apt-get install -y python3-pip python3-venv -qq
    python3 -m venv /opt/litellm
    /opt/litellm/bin/pip install -q litellm[proxy]
    
    # Create LiteLLM config
    cat > /opt/litellm/config.yaml <<'CONFIG'
    model_list:
      - model_name: deepseek-r1
        litellm_params:
          model: ollama/${var.deepseek_confidential_model}
          api_base: http://localhost:11434
    
    general_settings:
      master_key: sk-tee-deepseek-key
    CONFIG
    
    # Create LiteLLM systemd service
    cat > /etc/systemd/system/litellm.service <<'SERVICE'
    [Unit]
    Description=LiteLLM Proxy
    After=network.target ollama.service
    
    [Service]
    Type=simple
    ExecStart=/opt/litellm/bin/litellm --config /opt/litellm/config.yaml --port 4000 --host 0.0.0.0
    Restart=always
    RestartSec=10
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    systemctl daemon-reload
    systemctl enable litellm
    systemctl start litellm
    
    # Create README
    cat > /home/azureuser/README.md <<'README'
    # DeepSeek Confidential VM (TEE)
    
    ## Verify TEE Status
    dmesg | grep -i sev
    sudo cat /sys/kernel/security/sev 2>/dev/null || echo "Check attestation service"
    
    ## Test Ollama
    curl http://localhost:11434/api/generate -d '{"model":"${var.deepseek_confidential_model}","prompt":"Hello","stream":false}'
    
    ## Test LiteLLM
    curl http://localhost:4000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer sk-tee-deepseek-key' \
      -d '{"model":"deepseek-r1","messages":[{"role":"user","content":"Hello"}]}'
    
    ## Service Status
    systemctl status ollama
    systemctl status litellm
    README
    
    chown azureuser:azureuser /home/azureuser/README.md
    
    echo "=== Setup Complete ==="
    date
  EOF
  )
}

# Use azapi for Confidential VM since azurerm 3.x doesn't support it
resource "azapi_resource" "deepseek_confidential_vm" {
  count     = var.enable_deepseek_confidential ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-03-01"
  name      = "vibe-deepseek-cvm"
  location  = var.deepseek_confidential_location
  parent_id = data.azurerm_resource_group.vibe.id

  body = jsonencode({
    properties = {
      hardwareProfile = {
        vmSize = var.deepseek_confidential_vm_size
      }
      securityProfile = {
        securityType = "ConfidentialVM"
        uefiSettings = {
          secureBootEnabled = true
          vTpmEnabled       = true
        }
      }
      storageProfile = {
        imageReference = {
          publisher = "Canonical"
          offer     = "0001-com-ubuntu-confidential-vm-jammy"
          sku       = "22_04-lts-cvm"
          version   = "latest"
        }
        osDisk = {
          createOption = "FromImage"
          managedDisk = {
            storageAccountType = "Premium_LRS"
            securityProfile = {
              securityEncryptionType = "VMGuestStateOnly"
            }
          }
          diskSizeGB = 128
        }
      }
      osProfile = {
        computerName  = "deepseek-cvm"
        adminUsername = "azureuser"
        customData    = local.deepseek_confidential_cloud_init
        linuxConfiguration = {
          disablePasswordAuthentication = true
          ssh = {
            publicKeys = [
              {
                path    = "/home/azureuser/.ssh/authorized_keys"
                keyData = file("~/.ssh/id_rsa.pub")
              }
            ]
          }
        }
      }
      networkProfile = {
        networkInterfaces = [
          {
            id = azurerm_network_interface.deepseek_confidential[0].id
            properties = {
              primary = true
            }
          }
        ]
      }
    }
    zones = ["1"]
  })

  tags = {
    purpose     = "deepseek-confidential-vm"
    tee_type    = "Intel-TDX" # DC4es_v5 uses Intel TDX; DCasv5 would use AMD-SEV-SNP
    tee_enabled = "true"
    model       = var.deepseek_confidential_model
  }

  depends_on = [
    azurerm_network_interface.deepseek_confidential
  ]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "deepseek_confidential_enabled" {
  description = "Whether DeepSeek Confidential VM is enabled"
  value       = var.enable_deepseek_confidential
}

output "deepseek_confidential_public_ip" {
  description = "Public IP for SSH access"
  value       = var.enable_deepseek_confidential ? azurerm_public_ip.deepseek_confidential[0].ip_address : null
}

output "deepseek_confidential_ssh_command" {
  description = "SSH command to access the Confidential VM"
  value       = var.enable_deepseek_confidential ? "ssh azureuser@${azurerm_public_ip.deepseek_confidential[0].ip_address}" : null
}

output "deepseek_confidential_tee_verify" {
  description = "Command to verify TEE is active"
  value       = var.enable_deepseek_confidential ? "ssh azureuser@${azurerm_public_ip.deepseek_confidential[0].ip_address} 'dmesg | grep -i sev'" : null
}

output "deepseek_confidential_litellm_endpoint" {
  description = "LiteLLM API endpoint"
  value       = var.enable_deepseek_confidential ? "http://${azurerm_public_ip.deepseek_confidential[0].ip_address}:4000/v1/chat/completions" : null
}
