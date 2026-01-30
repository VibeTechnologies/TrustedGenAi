# TrustedGenAi

Privacy-preserving LLM inference with hardware-attested Trusted Execution Environments.

## Overview

TrustedGenAi provides self-hosted LLM inference on TEE hardware with cryptographic attestation. Users can verify that their prompts and responses never leave the encrypted memory enclave.

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

## Repository Structure

```
TrustedGenAi/
├── terraform/              # Infrastructure as Code
│   ├── main.tf            # Provider config, variables
│   ├── deepseek-tee-confidential.tf  # CPU TEE (Intel TDX)
│   └── deepseek-gpu-tee.tf           # GPU TEE (H100 CC) [projected]
├── scripts/                # Deployment scripts
│   └── attestation_server.py         # TEE attestation API
├── config/                 # Configuration files
│   └── litellm-config.yaml           # LiteLLM proxy config
├── docs/                   # Documentation
│   ├── tee-llm-infrastructure.tex    # arXiv whitepaper
│   ├── production-guide.md           # Production deployment
│   ├── attestation-verification.md   # Customer verification
│   └── gpu-tee-deepseek-v3.md        # GPU TEE guide
└── LICENSE                 # CC BY-NC-SA 4.0
```

## Open Source Components

This repository contains all components needed to deploy your own TEE LLM infrastructure:

| Component | File | Description |
|-----------|------|-------------|
| **Attestation API** | `scripts/attestation_server.py` | Python server providing cryptographic TEE proof |
| **LiteLLM Config** | `config/litellm-config.yaml` | OpenAI-compatible proxy configuration |
| **CPU TEE Terraform** | `terraform/deepseek-tee-confidential.tf` | Intel TDX VM deployment |
| **GPU TEE Terraform** | `terraform/deepseek-gpu-tee.tf` | NVIDIA H100 CC deployment (projected) |
| **Whitepaper** | `docs/tee-llm-infrastructure.tex` | Technical paper (arXiv format) |

## What's NOT in This Repo

Billing and subscription management are handled separately:

- **Stripe Integration**: Payment processing for VibeBrowser subscriptions
- **User Portal**: OAuth login and API key management
- **Budget Enforcement**: Per-user spending limits

These components are proprietary to [VibeBrowser](https://vibebrowser.app).

## Deployment Options

### CPU TEE (Intel TDX) - Production

```bash
cd terraform
terraform init
terraform apply -var="enable_cpu_tee=true"
```

| Spec | Value |
|------|-------|
| VM | Standard_DC4es_v5 |
| RAM | 16 GB |
| TEE | Intel TDX |
| Model | deepseek-r1:1.5b |
| Speed | ~12 tokens/sec |
| Cost | ~$216/month |

### GPU TEE (NVIDIA H100) - Projected

```bash
cd terraform
terraform init
terraform apply -var="enable_gpu_tee=true"
```

| Spec | Value |
|------|-------|
| VM | Standard_NCC40ads_H100_v5 |
| RAM | 320 GB |
| GPU | 1x H100 NVL (94GB) |
| TEE | AMD SEV-SNP + NVIDIA CC |
| Model | DeepSeek-R1-Distill-7B |
| Speed | ~150 tokens/sec (projected) |
| Cost | ~$6,300/month |

**Note**: GPU TEE has not been deployed. Performance numbers are projections based on hardware specifications.

## Attestation Response

```json
{
  "platform": "Intel-TDX",
  "tee_verified": true,
  "vm_size": "Standard_DC4es_v5",
  "azure_attestation": {
    "encoding": "pkcs7",
    "signature": "<Microsoft-signed PKCS7 document>"
  },
  "tpm_pcr_sha256": {
    "0": "<PCR value>",
    "1": "<PCR value>"
  },
  "tee_dmesg": [
    "Intel TDX: Guest initialized"
  ],
  "timestamp": "2026-01-29T12:00:00Z"
}
```

## Security Model

| Threat | Mitigation |
|--------|------------|
| Malicious cloud operator | TEE memory encryption (hardware-enforced) |
| Compromised service operator | Operator cannot access encrypted memory |
| Network adversary | TLS encryption |
| Software tampering | TPM PCR attestation |

## Related Projects

- [VibeBrowser](https://vibebrowser.app) - AI browser agent using TrustedGenAi backend
- [LiteLLM](https://github.com/BerriAI/litellm) - OpenAI-compatible proxy
- [DeepSeek](https://github.com/deepseek-ai) - Open-source LLM models

## License

This project is licensed under [CC BY-NC-SA 4.0](LICENSE) (Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International).

**You may:**
- Share and adapt the material
- Use for research and personal projects

**You may not:**
- Use for commercial purposes without permission
- Remove attribution

For commercial licensing, contact: dzianis_v@pm.me

## Citation

If you use this work in research, please cite:

```bibtex
@misc{trustedgenai2026,
  title={TrustedGenAi: Privacy-Preserving LLM Inference with Hardware-Attested Trusted Execution Environments},
  author={Vashchuk, Dzianis and Claude-Opus-4.5},
  year={2026},
  url={https://github.com/VibeTechnologies/TrustedGenAi}
}
```
