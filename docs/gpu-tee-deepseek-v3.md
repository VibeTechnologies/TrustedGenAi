# DeepSeek-V3 on GPU TEE (H100 Confidential Computing)

Guide for deploying DeepSeek-V3 (671B MoE) on Azure NCCads_H100_v5 with GPU Confidential Computing.

## Hardware Requirements

| Component | Specification |
|-----------|---------------|
| VM Size | Standard_NCC40ads_H100_v5 |
| vCPUs | 40 (AMD EPYC Genoa) |
| RAM | 320 GB |
| GPU | 1x NVIDIA H100 NVL |
| GPU Memory | 94 GB HBM3 |
| Storage | 256 GB Premium SSD |
| TEE | AMD SEV-SNP (CPU) + NVIDIA CC (GPU) |

## DeepSeek-V3 Model Sizing

DeepSeek-V3 uses Mixture of Experts (MoE) architecture:

| Metric | Value |
|--------|-------|
| Total Parameters | 671B |
| Activated Parameters | 37B (per token) |
| Expert Count | 256 |
| Experts per Token | 8 |

### VRAM Requirements by Precision

| Precision | VRAM Required | Fits on H100 (94GB)? |
|-----------|---------------|----------------------|
| FP32 | ~2.7 TB | No |
| FP16/BF16 | ~1.3 TB | No |
| FP8 | ~670 GB | No (need 8x H100) |
| INT4 (AWQ/GPTQ) | ~335 GB | No (need 4x H100) |
| FP8 distilled 7B | ~14 GB | Yes |

**Reality check**: Full DeepSeek-V3 requires 8x H100 cluster. For single H100, use:
- DeepSeek-V3-Distill-7B (FP8): ~14 GB VRAM
- DeepSeek-R1-Distill-Qwen-7B: ~14 GB VRAM
- DeepSeek-R1-Distill-Qwen-32B (INT4): ~20 GB VRAM

## Deployment Options

### Option 1: DeepSeek-R1 Distill (Recommended for Single H100)

```bash
# Install vLLM
pip install vllm

# Run DeepSeek-R1 distilled 7B
python -m vllm.entrypoints.openai.api_server \
  --model deepseek-ai/DeepSeek-R1-Distill-Qwen-7B \
  --dtype float16 \
  --port 8000 \
  --host 0.0.0.0 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.95

# Verify
curl http://localhost:8000/v1/models
```

Expected performance: ~100-200 tokens/sec on H100.

### Option 2: DeepSeek-R1 Distill 32B (INT4 Quantized)

```bash
# Run 32B with 4-bit quantization
python -m vllm.entrypoints.openai.api_server \
  --model deepseek-ai/DeepSeek-R1-Distill-Qwen-32B \
  --dtype float16 \
  --quantization awq \
  --port 8000 \
  --host 0.0.0.0 \
  --max-model-len 16384 \
  --gpu-memory-utilization 0.95
```

Expected performance: ~50-80 tokens/sec on H100.

### Option 3: Full DeepSeek-V3 (Multi-GPU Cluster)

For production DeepSeek-V3 (full 671B):

```bash
# Requires 8x H100 with tensor parallelism
python -m vllm.entrypoints.openai.api_server \
  --model deepseek-ai/DeepSeek-V3 \
  --dtype float16 \
  --tensor-parallel-size 8 \
  --port 8000 \
  --host 0.0.0.0 \
  --max-model-len 32768
```

Azure VM options for 8x H100:
- ND96isr_H100_v5: 8x H100 SXM, 640 GB HBM3, ~$27/hour

## Terraform Deployment

### Enable GPU TEE

```bash
cd services/subscription/terraform

# Deploy with DeepSeek-R1 distilled (default)
terraform apply -var="enable_deepseek_gpu_tee=true"

# Or specify model
terraform apply \
  -var="enable_deepseek_gpu_tee=true" \
  -var="deepseek_gpu_tee_model=deepseek-ai/DeepSeek-R1-Distill-Qwen-7B"
```

### Verify TEE

```bash
# SSH to VM
ssh azureuser@<public_ip>

# Verify AMD SEV-SNP (CPU TEE)
dmesg | grep -i sev

# Verify NVIDIA CC (GPU TEE)
nvidia-smi -q | grep -i confidential

# Check attestation
curl http://localhost:4001/v1/attestation | jq
```

### Destroy

```bash
terraform destroy -var="enable_deepseek_gpu_tee=true"
```

## GPU TEE Attestation

The attestation API returns both CPU and GPU TEE status:

```json
{
  "platform": "AMD-SEV-SNP",
  "gpu": "NVIDIA-H100-CC",
  "vm_size": "Standard_NCC40ads_H100_v5",
  "tee_verified": true,
  "gpu_tee_verified": true,
  "tee_dmesg": ["Memory encryption: AMD SEV-SNP"],
  "azure_attestation": {
    "encoding": "pkcs7",
    "signature": "..."
  }
}
```

## Cost Analysis

| Resource | Hourly | Monthly (730h) |
|----------|--------|----------------|
| NCC40ads_H100_v5 | ~$8.50 | ~$6,205 |
| Premium SSD 256GB | - | ~$35 |
| Network egress | Variable | ~$50-100 |
| **Total** | ~$8.50/hr | ~$6,300/month |

### Cost Optimization

1. **Spot instances**: Not available for confidential VMs
2. **Reserved instances**: 1-year = 30% savings, 3-year = 50% savings
3. **Auto-shutdown**: Schedule for off-hours if not 24/7

## Performance Expectations

| Model | H100 Tokens/sec | Latency (first token) |
|-------|-----------------|----------------------|
| DeepSeek-R1-Distill-7B | 150-200 | <100ms |
| DeepSeek-R1-Distill-32B (INT4) | 60-80 | <150ms |
| DeepSeek-V3 (8x H100) | 40-60 | <200ms |

## Comparison: CPU TEE vs GPU TEE

| Metric | CPU TEE (DC4es_v5) | GPU TEE (NCC40ads_H100_v5) |
|--------|-------------------|---------------------------|
| Cost | $216/month | $6,300/month |
| Model | deepseek-r1:1.5b | DeepSeek-R1-Distill-7B |
| Speed | 12 tok/s | 150+ tok/s |
| Quality | Good | Better |
| Use Case | Testing/Dev | Production |

## Migration Path

1. **Phase 1** (Current): CPU TEE with 1.5b model for validation
2. **Phase 2**: GPU TEE with 7B distill for beta users
3. **Phase 3**: Multi-GPU cluster for full DeepSeek-V3

## Known Limitations

1. **NVIDIA Confidential Computing**: Requires NVIDIA driver 550.90.07+
2. **Ubuntu 22.04 only**: Required for confidential GPU support
3. **Limited regions**: Only eastus2 and westeurope
4. **Quota required**: Must request NCCads_H100_v5 quota from Azure

## References

- [Azure Confidential GPU VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-gpu-overview)
- [NVIDIA Confidential Computing](https://developer.nvidia.com/confidential-computing)
- [DeepSeek-V3 Technical Report](https://github.com/deepseek-ai/DeepSeek-V3)
- [vLLM Documentation](https://docs.vllm.ai/)
