# TrustedGenAi

Trusted Execution Environment (TEE) infrastructure for LLM inference with cryptographic attestation.

## Overview

TrustedGenAi provides self-hosted LLM inference on hardware-isolated TEE environments with verifiable privacy guarantees. Users can cryptographically verify that their prompts and responses never leave the encrypted memory enclave.

## Features

- **Hardware-enforced confidentiality**: All data encrypted in-use via Intel TDX or AMD SEV-SNP
- **Remote attestation**: Cryptographic proof of TEE execution via Azure-signed PKCS7 documents
- **Self-hosted models**: DeepSeek R1 running on controlled infrastructure
- **OpenAI-compatible API**: Drop-in replacement via LiteLLM proxy

## Live Infrastructure

| Component | URL | Status |
|-----------|-----|--------|
| LiteLLM API | https://tee.vibebrowser.app/v1 | Production |
| Attestation | https://tee.vibebrowser.app/attestation | Production |

## Quick Start

### Verify TEE

```bash
curl -s https://tee.vibebrowser.app/attestation | jq '{platform, tee_verified, vm_size}'
```

Expected response:
```json
{
  "platform": "Intel-TDX",
  "tee_verified": true,
  "vm_size": "Standard_DC4es_v5"
}
```

### Chat Completion

```bash
curl -s https://tee.vibebrowser.app/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "deepseek-r1",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Deployment Options

### CPU TEE (Intel TDX)

- **VM**: Standard_DC4es_v5 (4 vCPU, 16GB RAM)
- **Cost**: ~$216/month
- **Model**: deepseek-r1:1.5b (~12 tokens/sec)
- **Use case**: Development, testing, low-volume privacy workloads

```bash
cd terraform
terraform init
terraform apply -var="enable_deepseek_confidential=true"
```

### GPU TEE (NVIDIA H100 CC)

- **VM**: Standard_NCC40ads_H100_v5 (40 vCPU, 320GB RAM, 1x H100)
- **Cost**: ~$6,300/month
- **Model**: DeepSeek-R1-Distill-7B (~150 tokens/sec)
- **Use case**: Production inference

```bash
cd terraform
terraform init
terraform apply -var="enable_deepseek_gpu_tee=true"
```

## Architecture

```
Client Application
       |
       v (HTTPS via Cloudflare Tunnel)
┌─────────────────────────────────────────┐
│  Azure Confidential VM (Intel TDX)      │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ LiteLLM (OpenAI-compatible API) │   │
│  └──────────────┬──────────────────┘   │
│                 v                       │
│  ┌─────────────────────────────────┐   │
│  │ Ollama / vLLM (Model Inference) │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ Attestation API                 │   │
│  │ - Azure-signed PKCS7 proof      │   │
│  │ - TPM PCR values                │   │
│  └─────────────────────────────────┘   │
│                                         │
│  [Hardware: TEE Memory Encryption]      │
└─────────────────────────────────────────┘
```

## Documentation

| Document | Description |
|----------|-------------|
| [docs/production-guide.md](docs/production-guide.md) | Production deployment guide |
| [docs/attestation-verification.md](docs/attestation-verification.md) | Customer verification guide |
| [docs/gpu-tee-deepseek-v3.md](docs/gpu-tee-deepseek-v3.md) | GPU TEE deployment |
| [docs/tee-llm-infrastructure.tex](docs/tee-llm-infrastructure.tex) | Technical whitepaper |

## Repository Structure

```
TrustedGenAi/
├── terraform/           # Infrastructure as Code
│   ├── main.tf         # Provider config, variables
│   ├── deepseek-tee-confidential.tf  # CPU TEE (Intel TDX)
│   └── deepseek-gpu-tee.tf           # GPU TEE (H100 CC)
├── docs/               # Documentation
│   ├── production-guide.md
│   ├── attestation-verification.md
│   └── tee-llm-infrastructure.tex
└── scripts/            # Deployment scripts
```

## Security Model

| Threat | Mitigation |
|--------|------------|
| Malicious cloud operator | TEE memory encryption (hardware-enforced) |
| Compromised service operator | Operator cannot access encrypted memory |
| Network adversary | TLS encryption via Cloudflare |
| Software tampering | TPM PCR attestation |

## Cost Analysis

| Deployment | Monthly Cost | Tokens/sec | Use Case |
|------------|--------------|------------|----------|
| CPU TEE | $216 | ~12 | Development |
| GPU TEE | $6,300 | ~150 | Production |
| API (GPT-4o) | Variable | N/A | No privacy guarantee |

## Related Projects

- [VibeBrowser](https://github.com/VibeTechnologies/VibeWebAgent) - AI browser agent using TrustedGenAi backend
- [LiteLLM](https://github.com/BerriAI/litellm) - OpenAI-compatible proxy
- [DeepSeek](https://github.com/deepseek-ai) - Open-source LLM models

## License

CC BY-NC-SA 4.0 (Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International)
