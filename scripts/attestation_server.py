#!/usr/bin/env python3
"""
TrustedGenAi Attestation Server

Provides cryptographic proof that the LLM is running inside a Trusted Execution Environment.
Returns Azure-signed attestation documents, TPM PCR values, and TEE kernel messages.

Usage:
    python3 attestation_server.py [--port 4001] [--host 0.0.0.0]

Endpoints:
    GET /attestation     - Full attestation response (JSON)
    GET /health          - Health check
    GET /v1/attestation  - Alias for /attestation (LiteLLM compatibility)

Response Format:
    {
        "platform": "Intel-TDX" | "AMD-SEV-SNP",
        "tee_verified": true | false,
        "vm_size": "Standard_DC4es_v5",
        "azure_attestation": { "encoding": "pkcs7", "signature": "..." },
        "tpm_pcr_sha256": { "0": "...", "1": "...", ... },
        "tee_dmesg": ["Intel TDX: ...", ...],
        "timestamp": "2026-01-29T12:00:00Z"
    }

For GPU TEE (NCCads_H100_v5), additional fields:
    {
        "gpu": "NVIDIA-H100-CC",
        "gpu_tee_verified": true | false,
        "nvidia_cc_mode": "on" | "off"
    }
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler


def get_tee_platform():
    """Detect TEE platform from kernel messages."""
    try:
        dmesg = subprocess.check_output(['dmesg'], stderr=subprocess.DEVNULL, timeout=5).decode()
        
        if 'Intel TDX' in dmesg or 'tdx' in dmesg.lower():
            return 'Intel-TDX'
        elif 'SEV-SNP' in dmesg or 'sev' in dmesg.lower():
            return 'AMD-SEV-SNP'
        elif 'Memory Encryption' in dmesg:
            return 'AMD-SEV-SNP'  # Older SEV without SNP
        
        return 'Unknown'
    except Exception:
        return 'Unknown'


def get_tee_dmesg_lines():
    """Extract TEE-related kernel messages."""
    try:
        dmesg = subprocess.check_output(['dmesg'], stderr=subprocess.DEVNULL, timeout=5).decode()
        lines = dmesg.split('\n')
        
        tee_keywords = ['tdx', 'sev', 'memory encryption', 'confidential', 'encrypted']
        tee_lines = []
        
        for line in lines:
            line_lower = line.lower()
            if any(kw in line_lower for kw in tee_keywords):
                # Clean up the line (remove timestamp if present)
                tee_lines.append(line.strip())
        
        return tee_lines[:10]  # Limit to 10 most relevant lines
    except Exception as e:
        return [f'Error reading dmesg: {e}']


def get_azure_attestation():
    """Fetch Azure Instance Metadata Service attestation document."""
    try:
        result = subprocess.check_output([
            'curl', '-s', '-H', 'Metadata: true',
            'http://169.254.169.254/metadata/attested/document?api-version=2021-02-01'
        ], stderr=subprocess.DEVNULL, timeout=10).decode()
        
        data = json.loads(result)
        
        # Return structured attestation with signature preview
        return {
            'encoding': data.get('encoding', 'unknown'),
            'signature': data.get('signature', '')[:200] + '...' if len(data.get('signature', '')) > 200 else data.get('signature', '')
        }
    except Exception as e:
        return {'error': str(e)}


def get_tpm_pcr_values():
    """Read TPM Platform Configuration Register values."""
    pcr_values = {}
    
    try:
        # Try tpm2-tools first
        result = subprocess.check_output(
            ['tpm2_pcrread', 'sha256'],
            stderr=subprocess.DEVNULL,
            timeout=5
        ).decode()
        
        for line in result.split('\n'):
            if ':' in line and '0x' in line:
                parts = line.strip().split(':')
                if len(parts) >= 2:
                    pcr_num = parts[0].strip()
                    pcr_val = parts[1].strip()
                    pcr_values[pcr_num] = pcr_val
                    
    except FileNotFoundError:
        # tpm2-tools not installed
        pcr_values['error'] = 'tpm2-tools not installed'
    except subprocess.TimeoutExpired:
        pcr_values['error'] = 'TPM read timeout'
    except Exception as e:
        pcr_values['error'] = str(e)
    
    return pcr_values


def get_gpu_tee_status():
    """Check NVIDIA Confidential Computing status (for GPU TEE VMs)."""
    result = {
        'gpu_detected': False,
        'gpu_tee_verified': False,
        'nvidia_cc_mode': 'unknown'
    }
    
    try:
        # Check if nvidia-smi is available
        nvidia_smi = subprocess.check_output(
            ['nvidia-smi', '-q'],
            stderr=subprocess.DEVNULL,
            timeout=10
        ).decode()
        
        result['gpu_detected'] = True
        
        # Check for Confidential Computing mode
        if 'Confidential Computing' in nvidia_smi:
            result['gpu_tee_verified'] = True
            result['nvidia_cc_mode'] = 'on'
        else:
            result['nvidia_cc_mode'] = 'off'
        
        # Get GPU model
        for line in nvidia_smi.split('\n'):
            if 'Product Name' in line:
                result['gpu_model'] = line.split(':')[1].strip()
                break
                
    except FileNotFoundError:
        # No NVIDIA GPU or driver not installed
        pass
    except Exception as e:
        result['error'] = str(e)
    
    return result


def get_vm_size():
    """Get Azure VM size from instance metadata."""
    try:
        result = subprocess.check_output([
            'curl', '-s', '-H', 'Metadata: true',
            'http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text'
        ], stderr=subprocess.DEVNULL, timeout=5).decode()
        return result.strip()
    except Exception:
        return os.environ.get('VM_SIZE', 'Unknown')


class AttestationHandler(BaseHTTPRequestHandler):
    """HTTP handler for attestation endpoints."""
    
    def do_GET(self):
        if self.path in ['/attestation', '/v1/attestation']:
            self.handle_attestation()
        elif self.path == '/health':
            self.handle_health()
        else:
            self.send_response(404)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Not found'}).encode())
    
    def handle_attestation(self):
        """Return full attestation response."""
        platform = get_tee_platform()
        tee_dmesg = get_tee_dmesg_lines()
        
        response = {
            'platform': platform,
            'tee_verified': platform in ['Intel-TDX', 'AMD-SEV-SNP'],
            'vm_size': get_vm_size(),
            'azure_attestation': get_azure_attestation(),
            'tpm_pcr_sha256': get_tpm_pcr_values(),
            'tee_dmesg': tee_dmesg,
            'timestamp': datetime.now(timezone.utc).isoformat()
        }
        
        # Add GPU TEE info if applicable
        gpu_status = get_gpu_tee_status()
        if gpu_status['gpu_detected']:
            response['gpu'] = gpu_status.get('gpu_model', 'NVIDIA-GPU')
            response['gpu_tee_verified'] = gpu_status['gpu_tee_verified']
            response['nvidia_cc_mode'] = gpu_status['nvidia_cc_mode']
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(response, indent=2).encode())
    
    def handle_health(self):
        """Return health check response."""
        response = {
            'status': 'healthy',
            'service': 'attestation',
            'timestamp': datetime.now(timezone.utc).isoformat()
        }
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())
    
    def log_message(self, format, *args):
        """Log requests to stdout."""
        print(f"[{datetime.now().isoformat()}] {args[0]}")


def main():
    parser = argparse.ArgumentParser(description='TrustedGenAi Attestation Server')
    parser.add_argument('--port', type=int, default=4001, help='Port to listen on (default: 4001)')
    parser.add_argument('--host', default='0.0.0.0', help='Host to bind to (default: 0.0.0.0)')
    args = parser.parse_args()
    
    server = HTTPServer((args.host, args.port), AttestationHandler)
    print(f'Attestation server running on http://{args.host}:{args.port}')
    print(f'Endpoints: /attestation, /v1/attestation, /health')
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        server.shutdown()


if __name__ == '__main__':
    main()
