# TEE Attestation Verification Guide

How to verify that your LLM requests are processed on genuine Trusted Execution Environment (TEE) hardware with cryptographic proof.

## Quick Verification

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

If `tee_verified` is `true`, the backend is running on genuine TEE hardware.

## What TEE Provides

| Protection | Description |
|------------|-------------|
| Memory Encryption | All RAM encrypted by hardware (Intel TDX) |
| Isolation | VM isolated from host, hypervisor, other tenants |
| Attestation | Cryptographic proof of hardware authenticity |
| Data Confidentiality | Your prompts/responses encrypted in memory |

## Attestation Response Fields

| Field | Description |
|-------|-------------|
| `platform` | TEE technology: `Intel-TDX` or `AMD-SEV-SNP` |
| `vm_size` | Azure VM size (DCx_v5 series = TEE capable) |
| `tee_verified` | `true` if all TEE checks pass |
| `azure_attestation.signature` | Microsoft-signed PKCS7 document proving VM identity |
| `tpm_pcr_sha256` | TPM Platform Configuration Register values |
| `tee_dmesg` | Kernel messages proving TEE activation |

## Full Attestation Response

```bash
curl -s https://tee.vibebrowser.app/attestation | jq .
```

```json
{
  "platform": "Intel-TDX",
  "vm_size": "Standard_DC4es_v5",
  "tee_verified": true,
  "azure_attestation": {
    "encoding": "pkcs7",
    "signature": "MIILoAYJKoZIhvcNAQcCoIILkTCCC40..."
  },
  "tpm_pcr_sha256": "sha256:\n    0 : 0x2ADE8023...",
  "tee_dmesg": ["Memory Encryption Features active: Intel TDX"]
}
```

## JavaScript Verification

### Basic Verification

```javascript
async function verifyTEE() {
  const response = await fetch('https://tee.vibebrowser.app/attestation');
  const attestation = await response.json();
  
  if (!attestation.tee_verified) {
    throw new Error('TEE verification failed');
  }
  
  if (attestation.platform !== 'Intel-TDX') {
    throw new Error(`Unexpected platform: ${attestation.platform}`);
  }
  
  return attestation;
}
```

### Verify Before Each Request

```javascript
async function chatWithVerifiedTEE(message) {
  // Step 1: Verify TEE
  const attestation = await verifyTEE();
  console.log('TEE verified:', attestation.platform, attestation.vm_size);
  
  // Step 2: Send chat request
  const response = await fetch('https://tee.vibebrowser.app/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer YOUR_API_KEY'
    },
    body: JSON.stringify({
      model: 'deepseek-r1',
      messages: [{ role: 'user', content: message }]
    })
  });
  
  return response.json();
}
```

### Advanced: Verify Azure Signature

```javascript
async function verifyAzureSignature(attestation) {
  // The azure_attestation.signature is a PKCS7 document
  // signed by Microsoft Azure's attestation service
  
  const pkcs7 = attestation.azure_attestation.signature;
  
  // Decode base64 PKCS7
  const binary = atob(pkcs7);
  
  // Parse the signed document
  // Contains: subscriptionId, vmId, timestamp, sku
  const contentMatch = binary.match(/\{.*\}/s);
  if (contentMatch) {
    const claims = JSON.parse(contentMatch[0]);
    console.log('VM ID:', claims.vmId);
    console.log('Subscription:', claims.subscriptionId);
    console.log('SKU:', claims.sku);
    console.log('Created:', claims.timeStamp.createdOn);
    console.log('Expires:', claims.timeStamp.expiresOn);
  }
  
  // For production: verify PKCS7 signature against Microsoft CA
  // See: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
}
```

## Verification Checklist

Before sending sensitive data, verify:

1. **TEE Active**: `tee_verified === true`
2. **Platform Correct**: `platform === 'Intel-TDX'` or `platform === 'AMD-SEV-SNP'`
3. **VM Size**: Starts with `DC` (e.g., `DC4es_v5`) - these are confidential VMs
4. **Fresh Attestation**: Check `azure_attestation` timestamp is recent
5. **Kernel Proof**: `tee_dmesg` contains TEE activation message

## TPM PCR Values

The `tpm_pcr_sha256` field contains Platform Configuration Register values:

| PCR | Purpose |
|-----|---------|
| PCR 0 | SRTM, BIOS, Host Platform Extensions |
| PCR 1 | Host Platform Configuration |
| PCR 2 | UEFI driver and application code |
| PCR 4 | Boot Manager code |
| PCR 7 | Secure Boot state |

These values can be used to verify the software stack has not been tampered with.

## Error Handling

```javascript
async function safeTEERequest(message) {
  try {
    const attestation = await verifyTEE();
    
    // Additional checks
    if (!attestation.tee_dmesg?.some(l => l.includes('Intel TDX'))) {
      throw new Error('TEE kernel proof missing');
    }
    
    return await chatWithVerifiedTEE(message);
    
  } catch (error) {
    if (error.message.includes('TEE')) {
      // Handle TEE verification failure
      console.error('TEE verification failed:', error.message);
      // Fall back to non-TEE endpoint or alert user
    }
    throw error;
  }
}
```

## VibeBrowser Extension Integration

The extension automatically verifies TEE attestation when using the `vibe-tee` provider:

1. Select "Self-Hosted TEE" in extension settings
2. Extension fetches attestation on first request
3. Attestation is cached and refreshed periodically
4. All requests go to verified TEE backend

## Endpoints

| Endpoint | URL | Purpose |
|----------|-----|---------|
| Attestation | `https://tee.vibebrowser.app/attestation` | TEE verification |
| Models | `https://tee.vibebrowser.app/v1/models` | List available models |
| Chat | `https://tee.vibebrowser.app/v1/chat/completions` | Chat completions |

## Security Considerations

1. **Always verify before sensitive operations**: Attestation proves the current state
2. **Check timestamps**: Azure attestation expires after 6 hours
3. **Use HTTPS**: All endpoints use TLS via Cloudflare Tunnel
4. **API key protection**: Keep your API key secure
5. **Defense in depth**: TEE is one layer - also encrypt sensitive data client-side

## References

- [Azure Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)
- [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html)
- [Azure Instance Metadata Service](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
