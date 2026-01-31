# ==============================================================================
# CPU TEE - Intel TDX (DCesv5 Series)
# ==============================================================================
#
# Intel Trust Domain Extensions (TDX) on Azure DCesv5 series
# - Memory encryption: AES-256-XTS with CPU-managed keys
# - Isolation: Hardware-enforced from hypervisor, other VMs, host OS
# - Attestation: Intel + Microsoft signed
#
# Cost: ~$216/month (Standard_DC4es_v5)
# Performance: ~12 tokens/sec with DeepSeek-R1 1.5B
#
# Enable: terraform apply -var="enable_intel_tdx=true"
# Verify: ssh azureuser@<ip> "dmesg | grep -i tdx"
#
# ==============================================================================

variable "enable_intel_tdx" {
  description = "Enable Intel TDX CPU TEE deployment"
  type        = bool
  default     = false
}

variable "intel_tdx_vm_size" {
  description = "Intel TDX VM size (DCesv5 series)"
  type        = string
  default     = "Standard_DC4es_v5" # 4 vCPU, 16GB RAM, ~$0.30/hr (~$216/mo)
}

variable "intel_tdx_model" {
  description = "Model to run on Intel TDX TEE"
  type        = string
  default     = "deepseek-r1:1.5b"
}

# ==============================================================================
# Network Infrastructure
# ==============================================================================

resource "azurerm_virtual_network" "intel_tdx" {
  count               = var.enable_intel_tdx ? 1 : 0
  name                = "tee-intel-tdx-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.10.0.0/16"]

  tags = {
    tee_type = "Intel-TDX"
  }
}

resource "azurerm_subnet" "intel_tdx" {
  count                = var.enable_intel_tdx ? 1 : 0
  name                 = "tee-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.intel_tdx[0].name
  address_prefixes     = ["10.10.0.0/24"]
}

resource "azurerm_network_security_group" "intel_tdx" {
  count               = var.enable_intel_tdx ? 1 : 0
  name                = "tee-intel-tdx-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

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
    name                       = "LiteLLM-API"
    priority                   = 1002
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
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4001"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    tee_type = "Intel-TDX"
  }
}

resource "azurerm_subnet_network_security_group_association" "intel_tdx" {
  count                     = var.enable_intel_tdx ? 1 : 0
  subnet_id                 = azurerm_subnet.intel_tdx[0].id
  network_security_group_id = azurerm_network_security_group.intel_tdx[0].id
}

resource "azurerm_public_ip" "intel_tdx" {
  count               = var.enable_intel_tdx ? 1 : 0
  name                = "tee-intel-tdx-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    tee_type = "Intel-TDX"
  }
}

resource "azurerm_network_interface" "intel_tdx" {
  count               = var.enable_intel_tdx ? 1 : 0
  name                = "tee-intel-tdx-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.intel_tdx[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.intel_tdx[0].id
  }

  tags = {
    tee_type = "Intel-TDX"
  }
}

# ==============================================================================
# Cloud-init for Intel TDX VM
# ==============================================================================

locals {
  intel_tdx_cloud_init = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    export HOME=/root
    exec > /var/log/tee-init.log 2>&1
    
    echo "=== Intel TDX TEE Setup ==="
    echo "Platform: Intel TDX"
    echo "VM Size: ${var.intel_tdx_vm_size}"
    echo "Model: ${var.intel_tdx_model}"
    date
    
    # Verify Intel TDX is active
    echo "Verifying Intel TDX..."
    dmesg | grep -i "Intel TDX" && echo "Intel TDX VERIFIED" || echo "WARNING: TDX not detected"
    
    # Install ollama
    echo "Installing ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable ollama
    systemctl start ollama
    sleep 10
    
    # Pull model
    echo "Pulling model: ${var.intel_tdx_model}"
    HOME=/root ollama pull ${var.intel_tdx_model}
    
    # Configure ollama to listen on all interfaces
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
    
    # LiteLLM config
    cat > /opt/litellm/config.yaml <<'CONFIG'
    model_list:
      - model_name: deepseek-r1
        litellm_params:
          model: ollama/${var.intel_tdx_model}
          api_base: http://localhost:11434
      - model_name: deepseek-r1-1.5b
        litellm_params:
          model: ollama/deepseek-r1:1.5b
          api_base: http://localhost:11434
    
    general_settings:
      master_key: ${var.tee_api_key}
    CONFIG
    
    # LiteLLM systemd service
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
    
    # Attestation API service
    cat > /opt/attestation-api.py <<'ATTESTATION'
    #!/usr/bin/env python3
    import json
    import subprocess
    import http.server
    import urllib.request

    class AttestationHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/attestation':
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                
                # Get TEE info
                dmesg = subprocess.run(['dmesg'], capture_output=True, text=True)
                tee_lines = [l for l in dmesg.stdout.split('\n') if 'TDX' in l or 'Memory Encryption' in l]
                
                # Get Azure attestation
                try:
                    req = urllib.request.Request(
                        'http://169.254.169.254/metadata/attested/document?api-version=2021-02-01',
                        headers={'Metadata': 'true'}
                    )
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        azure_attestation = json.loads(resp.read())
                except:
                    azure_attestation = None
                
                # Get TPM PCR values
                try:
                    pcr = subprocess.run(['tpm2_pcrread', 'sha256'], capture_output=True, text=True)
                    tpm_pcr = pcr.stdout
                except:
                    tpm_pcr = "TPM not available"
                
                response = {
                    "platform": "Intel-TDX",
                    "vm_size": "${var.intel_tdx_vm_size}",
                    "tee_verified": len(tee_lines) > 0,
                    "azure_attestation": azure_attestation,
                    "tpm_pcr_sha256": tpm_pcr,
                    "tee_dmesg": tee_lines[:5]
                }
                self.wfile.write(json.dumps(response, indent=2).encode())
            else:
                self.send_response(404)
                self.end_headers()
        
        def log_message(self, format, *args):
            pass

    if __name__ == '__main__':
        server = http.server.HTTPServer(('0.0.0.0', 4001), AttestationHandler)
        print('Attestation API running on port 4001')
        server.serve_forever()
    ATTESTATION
    
    chmod +x /opt/attestation-api.py
    
    cat > /etc/systemd/system/attestation.service <<'SERVICE'
    [Unit]
    Description=TEE Attestation API
    After=network.target
    
    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /opt/attestation-api.py
    Restart=always
    RestartSec=10
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    systemctl daemon-reload
    systemctl enable attestation
    systemctl start attestation
    
    echo "=== Intel TDX Setup Complete ==="
    date
  EOF
  )
}

# ==============================================================================
# Intel TDX Confidential VM
# ==============================================================================

resource "azapi_resource" "intel_tdx_vm" {
  count     = var.enable_intel_tdx ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-03-01"
  name      = "tee-intel-tdx"
  location  = var.location
  parent_id = azurerm_resource_group.main.id

  body = jsonencode({
    properties = {
      hardwareProfile = {
        vmSize = var.intel_tdx_vm_size
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
        computerName  = "tee-intel-tdx"
        adminUsername = "azureuser"
        customData    = local.intel_tdx_cloud_init
        linuxConfiguration = {
          disablePasswordAuthentication = true
          ssh = {
            publicKeys = [
              {
                path    = "/home/azureuser/.ssh/authorized_keys"
                keyData = file(var.ssh_public_key_path)
              }
            ]
          }
        }
      }
      networkProfile = {
        networkInterfaces = [
          {
            id = azurerm_network_interface.intel_tdx[0].id
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
    tee_type    = "Intel-TDX"
    tee_enabled = "true"
    model       = var.intel_tdx_model
    cost        = "$216/month"
  }

  depends_on = [azurerm_network_interface.intel_tdx]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "intel_tdx_enabled" {
  description = "Whether Intel TDX TEE is enabled"
  value       = var.enable_intel_tdx
}

output "intel_tdx_public_ip" {
  description = "Public IP of Intel TDX VM"
  value       = var.enable_intel_tdx ? azurerm_public_ip.intel_tdx[0].ip_address : null
}

output "intel_tdx_ssh" {
  description = "SSH command for Intel TDX VM"
  value       = var.enable_intel_tdx ? "ssh azureuser@${azurerm_public_ip.intel_tdx[0].ip_address}" : null
}

output "intel_tdx_api" {
  description = "LiteLLM API endpoint"
  value       = var.enable_intel_tdx ? "http://${azurerm_public_ip.intel_tdx[0].ip_address}:4000/v1" : null
}

output "intel_tdx_attestation" {
  description = "Attestation API endpoint"
  value       = var.enable_intel_tdx ? "http://${azurerm_public_ip.intel_tdx[0].ip_address}:4001/attestation" : null
}
