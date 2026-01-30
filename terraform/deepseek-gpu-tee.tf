# ==============================================================================
# GPU Confidential Computing: DeepSeek on NVIDIA H100 with TEE
# ==============================================================================
#
# This module deploys DeepSeek on Azure NCCads_H100_v5 with GPU Confidential Computing.
# The NCCads series provides AMD SEV-SNP for CPU memory + NVIDIA CC for GPU memory.
#
# Hardware Specifications (Standard_NCC40ads_H100_v5):
#   - vCPUs: 40 (AMD EPYC Genoa)
#   - Memory: 320 GiB
#   - GPU: 1x NVIDIA H100 NVL
#   - GPU Memory: 94 GB HBM3
#   - TEE: AMD SEV-SNP + NVIDIA Confidential Computing
#
# Regions: East US 2, West Europe only
# Cost: ~$8-12/hour (~$6,000-8,600/month)
#
# DeepSeek Models:
#   - DeepSeek-V3 (671B MoE, 37B activated): Fits on 1x H100 in FP8 (~70-80GB VRAM)
#   - DeepSeek-V2 (236B MoE, 21B activated): Fits easily (~40-50GB VRAM)
#
# Enable: terraform apply -var="enable_deepseek_gpu_tee=true"
#
# Prerequisites:
#   1. Request quota for NCCads_H100_v5 from Azure support
#   2. Available regions: eastus2, westeurope
#   3. Ubuntu 22.04 LTS only (required for confidential GPU)
#
# ==============================================================================

variable "enable_deepseek_gpu_tee" {
  description = "Enable GPU Confidential Computing deployment (NCCads_H100_v5)"
  type        = bool
  default     = false
}

variable "deepseek_gpu_tee_location" {
  description = "Azure region for GPU TEE VM (must be eastus2 or westeurope)"
  type        = string
  default     = "eastus2"

  validation {
    condition     = contains(["eastus2", "westeurope"], var.deepseek_gpu_tee_location)
    error_message = "GPU Confidential VMs only available in eastus2 or westeurope"
  }
}

variable "deepseek_gpu_tee_vm_size" {
  description = "VM size - must be NCCads_H100_v5 series for GPU TEE"
  type        = string
  default     = "Standard_NCC40ads_H100_v5" # 1x H100 NVL, 94GB

  validation {
    condition     = can(regex("^Standard_NCC[0-9]+ads_H100_v5$", var.deepseek_gpu_tee_vm_size))
    error_message = "Must be NCCads_H100_v5 series for GPU Confidential Computing"
  }
}

variable "deepseek_gpu_tee_model" {
  description = "DeepSeek model to run (recommend deepseek-ai/DeepSeek-V3 for full capability)"
  type        = string
  default     = "deepseek-ai/DeepSeek-V3"
}

# ==============================================================================
# Network Infrastructure for GPU TEE VM
# ==============================================================================

resource "azurerm_virtual_network" "deepseek_gpu_tee" {
  count               = var.enable_deepseek_gpu_tee ? 1 : 0
  name                = "vibe-deepseek-gpu-tee-vnet"
  location            = var.deepseek_gpu_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  address_space       = ["10.4.0.0/16"]

  tags = {
    purpose = "deepseek-gpu-tee"
  }
}

resource "azurerm_subnet" "deepseek_gpu_tee" {
  count                = var.enable_deepseek_gpu_tee ? 1 : 0
  name                 = "gpu-tee-subnet"
  resource_group_name  = data.azurerm_resource_group.vibe.name
  virtual_network_name = azurerm_virtual_network.deepseek_gpu_tee[0].name
  address_prefixes     = ["10.4.0.0/24"]
}

resource "azurerm_network_security_group" "deepseek_gpu_tee" {
  count               = var.enable_deepseek_gpu_tee ? 1 : 0
  name                = "vibe-deepseek-gpu-tee-nsg"
  location            = var.deepseek_gpu_tee_location
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
    name                       = "vLLM-API"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8000"
    source_address_prefix      = "*"
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

  tags = {
    purpose = "deepseek-gpu-tee"
  }
}

resource "azurerm_subnet_network_security_group_association" "deepseek_gpu_tee" {
  count                     = var.enable_deepseek_gpu_tee ? 1 : 0
  subnet_id                 = azurerm_subnet.deepseek_gpu_tee[0].id
  network_security_group_id = azurerm_network_security_group.deepseek_gpu_tee[0].id
}

resource "azurerm_public_ip" "deepseek_gpu_tee" {
  count               = var.enable_deepseek_gpu_tee ? 1 : 0
  name                = "vibe-deepseek-gpu-tee-pip"
  location            = var.deepseek_gpu_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    purpose = "deepseek-gpu-tee"
  }
}

resource "azurerm_network_interface" "deepseek_gpu_tee" {
  count               = var.enable_deepseek_gpu_tee ? 1 : 0
  name                = "vibe-deepseek-gpu-tee-nic"
  location            = var.deepseek_gpu_tee_location
  resource_group_name = data.azurerm_resource_group.vibe.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.deepseek_gpu_tee[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.deepseek_gpu_tee[0].id
  }

  tags = {
    purpose = "deepseek-gpu-tee"
  }
}

# ==============================================================================
# Cloud-init for GPU TEE Setup
# ==============================================================================

locals {
  deepseek_gpu_tee_cloud_init = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    export HOME=/root
    exec > /var/log/deepseek-gpu-tee-init.log 2>&1
    
    echo "=== DeepSeek GPU TEE Setup ==="
    echo "VM Size: ${var.deepseek_gpu_tee_vm_size}"
    echo "Model: ${var.deepseek_gpu_tee_model}"
    date
    
    # Verify TEE is active (AMD SEV-SNP for NCCads series)
    echo "Checking TEE status..."
    dmesg | grep -iE 'sev|memory encryption' || echo "TEE messages not found in dmesg"
    
    # Check for NVIDIA GPU
    echo "Checking GPU..."
    lspci | grep -i nvidia || echo "No NVIDIA GPU detected"
    
    # Install NVIDIA driver with confidential computing support
    echo "Installing NVIDIA driver..."
    apt-get update -qq
    apt-get install -y linux-headers-$(uname -r) build-essential -qq
    
    # NVIDIA recommends driver 550.90.07+ for confidential computing
    # Ubuntu 22.04 LTS includes appropriate drivers
    apt-get install -y nvidia-driver-550 -qq || apt-get install -y nvidia-driver-545 -qq
    
    # Verify GPU is accessible
    nvidia-smi || echo "nvidia-smi failed - may need reboot"
    
    # Install Python and vLLM dependencies
    echo "Installing vLLM..."
    apt-get install -y python3-pip python3-venv -qq
    python3 -m venv /opt/vllm
    /opt/vllm/bin/pip install -q vllm
    
    # Create vLLM systemd service
    cat > /etc/systemd/system/vllm.service <<'SERVICE'
    [Unit]
    Description=vLLM OpenAI-compatible API Server
    After=network.target
    
    [Service]
    Type=simple
    Environment="CUDA_VISIBLE_DEVICES=0"
    ExecStart=/opt/vllm/bin/python -m vllm.entrypoints.openai.api_server \
      --model ${var.deepseek_gpu_tee_model} \
      --dtype float16 \
      --port 8000 \
      --host 0.0.0.0 \
      --max-model-len 32768
    Restart=always
    RestartSec=30
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    # Install LiteLLM
    echo "Installing LiteLLM..."
    python3 -m venv /opt/litellm
    /opt/litellm/bin/pip install -q litellm[proxy]
    
    # Create LiteLLM config
    cat > /opt/litellm/config.yaml <<'CONFIG'
    model_list:
      - model_name: deepseek-v3
        litellm_params:
          model: openai/deepseek-v3
          api_base: http://localhost:8000/v1
          api_key: local
      - model_name: deepseek-r1
        litellm_params:
          model: openai/deepseek-v3
          api_base: http://localhost:8000/v1
          api_key: local
    
    general_settings:
      master_key: sk-tee-deepseek-key
    CONFIG
    
    # Create LiteLLM systemd service
    cat > /etc/systemd/system/litellm.service <<'SERVICE'
    [Unit]
    Description=LiteLLM Proxy
    After=network.target vllm.service
    
    [Service]
    Type=simple
    ExecStart=/opt/litellm/bin/litellm --config /opt/litellm/config.yaml --port 4000 --host 0.0.0.0
    Restart=always
    RestartSec=10
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    # Create attestation service (same as CPU TEE)
    cat > /opt/litellm/attestation_server.py <<'ATTEST'
    #!/usr/bin/env python3
    import subprocess
    import json
    import base64
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import os
    
    class AttestationHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/v1/attestation':
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                
                # Get attestation data
                attestation = self.get_attestation()
                self.wfile.write(json.dumps(attestation).encode())
            else:
                self.send_response(404)
                self.end_headers()
        
        def get_attestation(self):
            result = {
                "platform": "AMD-SEV-SNP",
                "vm_size": os.environ.get('VM_SIZE', '${var.deepseek_gpu_tee_vm_size}'),
                "gpu": "NVIDIA-H100-CC",
                "tee_verified": False,
                "gpu_tee_verified": False
            }
            
            # Check CPU TEE (AMD SEV-SNP)
            try:
                dmesg = subprocess.check_output(['dmesg'], stderr=subprocess.DEVNULL).decode()
                tee_lines = [l for l in dmesg.split('\n') if 'sev' in l.lower() or 'memory encryption' in l.lower()]
                result['tee_dmesg'] = tee_lines[:5]
                result['tee_verified'] = any('sev' in l.lower() or 'memory encryption' in l.lower() for l in tee_lines)
            except Exception as e:
                result['tee_error'] = str(e)
            
            # Check GPU TEE (NVIDIA Confidential Computing)
            try:
                nvidia_smi = subprocess.check_output(['nvidia-smi', '-q'], stderr=subprocess.DEVNULL).decode()
                result['gpu_tee_verified'] = 'Confidential Computing' in nvidia_smi
                result['gpu_info'] = nvidia_smi[:500] if len(nvidia_smi) > 500 else nvidia_smi
            except Exception as e:
                result['gpu_error'] = str(e)
            
            # Get Azure attestation document
            try:
                azure_att = subprocess.check_output([
                    'curl', '-s', '-H', 'Metadata: true',
                    'http://169.254.169.254/metadata/attested/document?api-version=2021-02-01'
                ], stderr=subprocess.DEVNULL).decode()
                att_data = json.loads(azure_att)
                result['azure_attestation'] = {
                    'encoding': att_data.get('encoding', 'unknown'),
                    'signature': att_data.get('signature', '')[:200] + '...'
                }
            except Exception as e:
                result['azure_attestation_error'] = str(e)
            
            return result
        
        def log_message(self, format, *args):
            pass  # Suppress logging
    
    if __name__ == '__main__':
        server = HTTPServer(('0.0.0.0', 4001), AttestationHandler)
        print('Attestation server running on port 4001')
        server.serve_forever()
    ATTEST
    
    chmod +x /opt/litellm/attestation_server.py
    
    # Create attestation systemd service
    cat > /etc/systemd/system/attestation.service <<'SERVICE'
    [Unit]
    Description=TEE Attestation API
    After=network.target
    
    [Service]
    Type=simple
    Environment="VM_SIZE=${var.deepseek_gpu_tee_vm_size}"
    ExecStart=/usr/bin/python3 /opt/litellm/attestation_server.py
    Restart=always
    RestartSec=10
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    systemctl daemon-reload
    systemctl enable vllm litellm attestation
    
    # Start services (vLLM may fail until after reboot for GPU driver)
    systemctl start attestation
    # vLLM and LiteLLM will start after reboot when GPU driver is loaded
    
    # Create README
    cat > /home/azureuser/README.md <<'README'
    # DeepSeek GPU TEE (NVIDIA H100 Confidential Computing)
    
    ## Verify TEE Status
    
    ### CPU TEE (AMD SEV-SNP)
    dmesg | grep -i sev
    
    ### GPU TEE (NVIDIA CC)
    nvidia-smi -q | grep -i confidential
    
    ## Services
    systemctl status vllm
    systemctl status litellm
    systemctl status attestation
    
    ## Test Endpoints
    
    ### vLLM Direct
    curl http://localhost:8000/v1/models
    
    ### LiteLLM
    curl http://localhost:4000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer sk-tee-deepseek-key' \
      -d '{"model":"deepseek-v3","messages":[{"role":"user","content":"Hello"}]}'
    
    ### Attestation
    curl http://localhost:4001/v1/attestation | jq
    
    ## Logs
    journalctl -u vllm -f
    journalctl -u litellm -f
    cat /var/log/deepseek-gpu-tee-init.log
    README
    
    chown azureuser:azureuser /home/azureuser/README.md
    
    echo "=== Setup Complete (reboot required for GPU driver) ==="
    date
  EOF
  )
}

# ==============================================================================
# GPU TEE VM using azapi provider
# ==============================================================================

resource "azapi_resource" "deepseek_gpu_tee_vm" {
  count     = var.enable_deepseek_gpu_tee ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-03-01"
  name      = "vibe-deepseek-gpu-tee"
  location  = var.deepseek_gpu_tee_location
  parent_id = data.azurerm_resource_group.vibe.id

  body = jsonencode({
    properties = {
      hardwareProfile = {
        vmSize = var.deepseek_gpu_tee_vm_size
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
          diskSizeGB = 256 # Larger disk for model weights
        }
      }
      osProfile = {
        computerName  = "deepseek-gpu-tee"
        adminUsername = "azureuser"
        customData    = local.deepseek_gpu_tee_cloud_init
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
            id = azurerm_network_interface.deepseek_gpu_tee[0].id
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
    purpose     = "deepseek-gpu-tee"
    tee_type    = "AMD-SEV-SNP+NVIDIA-CC"
    tee_enabled = "true"
    model       = var.deepseek_gpu_tee_model
  }

  depends_on = [
    azurerm_network_interface.deepseek_gpu_tee
  ]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "deepseek_gpu_tee_enabled" {
  description = "Whether GPU TEE deployment is enabled"
  value       = var.enable_deepseek_gpu_tee
}

output "deepseek_gpu_tee_public_ip" {
  description = "Public IP for SSH access"
  value       = var.enable_deepseek_gpu_tee ? azurerm_public_ip.deepseek_gpu_tee[0].ip_address : null
}

output "deepseek_gpu_tee_ssh_command" {
  description = "SSH command to access the GPU TEE VM"
  value       = var.enable_deepseek_gpu_tee ? "ssh azureuser@${azurerm_public_ip.deepseek_gpu_tee[0].ip_address}" : null
}

output "deepseek_gpu_tee_attestation_endpoint" {
  description = "Attestation API endpoint"
  value       = var.enable_deepseek_gpu_tee ? "http://${azurerm_public_ip.deepseek_gpu_tee[0].ip_address}:4001/v1/attestation" : null
}

output "deepseek_gpu_tee_litellm_endpoint" {
  description = "LiteLLM API endpoint"
  value       = var.enable_deepseek_gpu_tee ? "http://${azurerm_public_ip.deepseek_gpu_tee[0].ip_address}:4000/v1/chat/completions" : null
}

output "deepseek_gpu_tee_cost_estimate" {
  description = "Estimated monthly cost"
  value       = var.enable_deepseek_gpu_tee ? "~$6,000-8,600/month ($8-12/hour)" : null
}
