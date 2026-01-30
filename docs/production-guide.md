# TEE-Hosted DeepSeek LLM Backend

Production-ready self-hosted LLM with cryptographic attestation for VibeBrowser customers.

## Live Endpoints

| Endpoint | URL | Purpose |
|----------|-----|---------|
| LiteLLM API | https://tee.vibebrowser.app/v1 | OpenAI-compatible chat completions |
| Attestation | https://tee.vibebrowser.app/attestation | TEE cryptographic proof |
| Direct (internal) | http://20.114.142.92:4000 | Bypass Cloudflare (debug only) |

See [attestation-verification.md](attestation-verification.md) for customer-facing verification guide.

## Quick Start

### 1. Verify TEE (Cryptographic Proof)

```bash
curl -s https://tee.vibebrowser.app/attestation | jq '{platform, tee_verified, vm_size}'
```

Response:
```json
{
  "platform": "Intel-TDX",
  "tee_verified": true,
  "vm_size": "Standard_DC4es_v5"
}
```

### 2. Chat Completion

```bash
curl -s https://tee.vibebrowser.app/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-tee-deepseek-key" \
  -d '{
    "model": "deepseek-r1",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Architecture

```
Customer Browser Extension
         |
         v (HTTPS via Cloudflare Tunnel)
    ┌─────────────────────────────────────────┐
    │  Azure Confidential VM (Intel TDX)      │
    │  Standard_DC4es_v5 - $216/month         │
    │                                         │
    │  ┌─────────────────────────────────┐   │
    │  │ Cloudflared + Nginx             │   │
    │  │ - HTTPS termination             │   │
    │  │ - Routes /v1/* -> LiteLLM       │   │
    │  │ - Routes /attestation -> API    │   │
    │  └──────────────┬──────────────────┘   │
    │                 v                       │
    │  ┌─────────────────────────────────┐   │
    │  │ LiteLLM (port 4000)             │   │
    │  │ - OpenAI-compatible API         │   │
    │  │ - API key authentication        │   │
    │  └──────────────┬──────────────────┘   │
    │                 v                       │
    │  ┌─────────────────────────────────┐   │
    │  │ Ollama (port 11434)             │   │
    │  │ - deepseek-r1:1.5b (fastest)    │   │
    │  │ - deepseek-r1:7b (better)       │   │
    │  └─────────────────────────────────┘   │
    │                                         │
    │  ┌─────────────────────────────────┐   │
    │  │ Attestation API (port 4001)     │   │
    │  │ - /v1/attestation               │   │
    │  │ - Azure-signed PKCS7 proof      │   │
    │  │ - TPM PCR values                │   │
    │  └─────────────────────────────────┘   │
    │                                         │
    │  [Hardware: Intel TDX Memory Encryption]│
    └─────────────────────────────────────────┘
```

## Available Models

| Model | Size | Speed | Quality | Use Case |
|-------|------|-------|---------|----------|
| `deepseek-r1` | 1.1GB | ~12 tok/s | Good | Default, fast responses |
| `deepseek-r1-1.5b` | 1.1GB | ~12 tok/s | Good | Alias for deepseek-r1 |
| `deepseek-r1-7b` | 4.7GB | ~0.7 tok/s | Better | Complex reasoning |

## Attestation Verification

The attestation endpoint returns cryptographic proof that:
1. VM is running on Intel TDX hardware (memory encryption)
2. Azure-signed PKCS7 document proves VM identity
3. TPM PCR values prove software integrity

### Full Attestation Response

```json
{
  "platform": "Intel-TDX",
  "vm_size": "Standard_DC4es_v5",
  "tee_verified": true,
  "azure_attestation": {
    "encoding": "pkcs7",
    "signature": "<base64 Microsoft-signed document>"
  },
  "tpm_pcr_sha256": "sha256:\n    0 : 0x2ADE8023...",
  "tee_dmesg": ["Memory Encryption Features active: Intel TDX"]
}
```

### JavaScript Verification

```javascript
async function verifyTEEAndChat(message) {
  const TEE_API = 'https://tee.vibebrowser.app';
  
  // Step 1: Verify TEE
  const att = await fetch(`${TEE_API}/attestation`).then(r => r.json());
  
  if (!att.tee_verified) {
    throw new Error('TEE verification failed');
  }
  
  if (!att.tee_dmesg.some(l => l.includes('Intel TDX'))) {
    throw new Error('Not running on Intel TDX');
  }
  
  // Step 2: Chat with verified TEE backend
  const resp = await fetch(`${TEE_API}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer sk-tee-deepseek-key'
    },
    body: JSON.stringify({
      model: 'deepseek-r1',
      messages: [{ role: 'user', content: message }]
    })
  });
  
  return resp.json();
}
```

## Infrastructure

### Terraform

```bash
cd services/subscription/terraform

# Deploy
terraform apply -var="enable_deepseek_confidential=true"

# Destroy (saves $216/month)
terraform destroy -var="enable_deepseek_confidential=true"
```

### SSH Access

```bash
ssh azureuser@20.114.142.92

# Check services
systemctl status ollama litellm attestation

# View TEE proof
sudo dmesg | grep -i tdx
```

### Files

| File | Purpose |
|------|---------|
| `services/subscription/terraform/deepseek-tee-confidential.tf` | VM infrastructure |
| `/home/azureuser/litellm-config.yaml` | LiteLLM model config |
| `/home/azureuser/attestation-server.py` | Attestation API |

## Cost

| Resource | Cost |
|----------|------|
| DC4es_v5 (4 vCPU, 16GB) | ~$0.30/hr (~$216/month) |
| Storage (128GB Premium SSD) | ~$10/month |
| Network egress | Usage-based |

## Security Notes

1. **TEE Protection**: All memory encrypted by Intel TDX hardware
2. **API Key**: Currently `sk-tee-deepseek-key` - change for production
3. **Network**: Currently HTTP - add Cloudflare/TLS for production
4. **Attestation**: Verify before every sensitive operation

## Next Steps for Production

1. [x] Add HTTPS via Cloudflare Tunnel
2. [ ] Rotate API key and store in Azure Key Vault
3. [ ] Add rate limiting in LiteLLM config
4. [ ] Consider GPU TEE (NCC H100) for faster inference
5. [ ] Integrate attestation verification in browser extension
