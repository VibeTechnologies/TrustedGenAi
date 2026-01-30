# ==============================================================================
# CPU TEE - AMD SEV-SNP (DCasv5 Series)
# ==============================================================================
#
# AMD Secure Encrypted Virtualization - Secure Nested Paging (SEV-SNP)
# - Memory encryption: AES-128 with AMD Secure Processor managed keys
# - Isolation: Hardware-enforced from hypervisor, other VMs, host OS
# - Attestation: AMD + Microsoft signed
#
# Cost: ~$140/month (Standard_DC4as_v5) - 35% CHEAPER than Intel TDX
# Performance: ~12 tokens/sec with DeepSeek-R1 1.5B
#
# Enable: terraform apply -var="enable_amd_sev=true"
# Verify: ssh azureuser@<ip> "dmesg | grep -i sev"
#
# ==============================================================================

variable "enable_amd_sev" {
  description = "Enable AMD SEV-SNP CPU TEE deployment"
  type        = bool
  default     = false
}

variable "amd_sev_vm_size" {
  description = "AMD SEV-SNP VM size (DCasv5 series)"
  type        = string
  default     = "Standard_DC4as_v5" # 4 vCPU, 16GB RAM, ~$0.19/hr (~$140/mo)
}

variable "amd_sev_model" {
  description = "Model to run on AMD SEV-SNP TEE"
  type        = string
  default     = "deepseek-r1:1.5b"
}

# ==============================================================================
# Network Infrastructure
# ==============================================================================

resource "azurerm_virtual_network" "amd_sev" {
  count               = var.enable_amd_sev ? 1 : 0
  name                = "tee-amd-sev-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.20.0.0/16"]

  tags = {
    tee_type = "AMD-SEV-SNP"
  }
}

resource "azurerm_subnet" "amd_sev" {
  count                = var.enable_amd_sev ? 1 : 0
  name                 = "tee-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.amd_sev[0].name
  address_prefixes     = ["10.20.0.0/24"]
}

resource "azurerm_network_security_group" "amd_sev" {
  count               = var.enable_amd_sev ? 1 : 0
  name                = "tee-amd-sev-nsg"
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
    tee_type = "AMD-SEV-SNP"
  }
}

resource "azurerm_subnet_network_security_group_association" "amd_sev" {
  count                     = var.enable_amd_sev ? 1 : 0
  subnet_id                 = azurerm_subnet.amd_sev[0].id
  network_security_group_id = azurerm_network_security_group.amd_sev[0].id
}

resource "azurerm_public_ip" "amd_sev" {
  count               = var.enable_amd_sev ? 1 : 0
  name                = "tee-amd-sev-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    tee_type = "AMD-SEV-SNP"
  }
}

resource "azurerm_network_interface" "amd_sev" {
  count               = var.enable_amd_sev ? 1 : 0
  name                = "tee-amd-sev-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.amd_sev[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.amd_sev[0].id
  }

  tags = {
    tee_type = "AMD-SEV-SNP"
  }
}

# ==============================================================================
# Cloud-init for AMD SEV-SNP VM
# ==============================================================================

locals {
  amd_sev_cloud_init = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    
    export HOME=/root
    exec > /var/log/tee-init.log 2>&1
    
    echo "=== AMD SEV-SNP TEE Setup ==="
    echo "Platform: AMD SEV-SNP"
    echo "VM Size: ${var.amd_sev_vm_size}"
    echo "Model: ${var.amd_sev_model}"
    date
    
    # Verify AMD SEV-SNP is active
    echo "Verifying AMD SEV-SNP..."
    dmesg | grep -i "SEV-SNP" && echo "AMD SEV-SNP VERIFIED" || echo "WARNING: SEV-SNP not detected"
    dmesg | grep -i "Memory Encryption" || true
    
    # Install ollama
    echo "Installing ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable ollama
    systemctl start ollama
    sleep 10
    
    # Pull model
    echo "Pulling model: ${var.amd_sev_model}"
    HOME=/root ollama pull ${var.amd_sev_model}
    
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
          model: ollama/${var.amd_sev_model}
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
                
                # Get TEE info from dmesg
                dmesg = subprocess.run(['dmesg'], capture_output=True, text=True)
                tee_lines = [l for l in dmesg.stdout.split('\n') 
                             if 'SEV' in l or 'Memory Encryption' in l]
                
                # Get Azure attestation document (PKCS7 signed by Microsoft)
                try:
                    req = urllib.request.Request(
                        'http://169.254.169.254/metadata/attested/document?api-version=2021-02-01',
                        headers={'Metadata': 'true'}
                    )
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        azure_attestation = json.loads(resp.read())
                except Exception as e:
                    azure_attestation = {"error": str(e)}
                
                # Get TPM PCR values
                try:
                    pcr = subprocess.run(['tpm2_pcrread', 'sha256'], capture_output=True, text=True)
                    tpm_pcr = pcr.stdout
                except:
                    tpm_pcr = "TPM not available"
                
                response = {
                    "platform": "AMD-SEV-SNP",
                    "vm_size": "${var.amd_sev_vm_size}",
                    "tee_verified": any('SEV' in l for l in tee_lines),
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
    
    echo "=== AMD SEV-SNP Setup Complete ==="
    date
  EOF
  )
}

# ==============================================================================
# AMD SEV-SNP Confidential VM
# ==============================================================================

resource "azapi_resource" "amd_sev_vm" {
  count     = var.enable_amd_sev ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-03-01"
  name      = "tee-amd-sev"
  location  = var.location
  parent_id = azurerm_resource_group.main.id

  body = jsonencode({
    properties = {
      hardwareProfile = {
        vmSize = var.amd_sev_vm_size
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
        computerName  = "tee-amd-sev"
        adminUsername = "azureuser"
        customData    = local.amd_sev_cloud_init
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
            id = azurerm_network_interface.amd_sev[0].id
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
    tee_type    = "AMD-SEV-SNP"
    tee_enabled = "true"
    model       = var.amd_sev_model
    cost        = "$140/month"
  }

  depends_on = [azurerm_network_interface.amd_sev]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "amd_sev_enabled" {
  description = "Whether AMD SEV-SNP TEE is enabled"
  value       = var.enable_amd_sev
}

output "amd_sev_public_ip" {
  description = "Public IP of AMD SEV-SNP VM"
  value       = var.enable_amd_sev ? azurerm_public_ip.amd_sev[0].ip_address : null
}

output "amd_sev_ssh" {
  description = "SSH command for AMD SEV-SNP VM"
  value       = var.enable_amd_sev ? "ssh azureuser@${azurerm_public_ip.amd_sev[0].ip_address}" : null
}

output "amd_sev_api" {
  description = "LiteLLM API endpoint"
  value       = var.enable_amd_sev ? "http://${azurerm_public_ip.amd_sev[0].ip_address}:4000/v1" : null
}

output "amd_sev_attestation" {
  description = "Attestation API endpoint"
  value       = var.enable_amd_sev ? "http://${azurerm_public_ip.amd_sev[0].ip_address}:4001/attestation" : null
}
