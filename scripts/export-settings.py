"""Print shell exports for non-secret Terraform outputs only."""
import json
import shlex
import subprocess

outputs = json.loads(subprocess.check_output(
    ['terraform', '-chdir=infra-terraform', 'output', '-json'], text=True))
mapping = {
    'AZURE_SUBSCRIPTION_ID': 'subscription_id',
    'AZURE_TENANT_ID': 'tenant_id',
    'RESOURCE_GROUP': 'resource_group',
    'AKS_NAME': 'aks_name',
    'ACR_NAME': 'acr_name',
    'ACR_LOGIN_SERVER': 'acr_login_server',
    'KEY_VAULT_NAME': 'key_vault_name',
    'WORKLOAD_CLIENT_ID': 'workload_client_id',
}
for environment_name, output_name in mapping.items():
    item = outputs.get(output_name)
    if not item or item.get('sensitive') or not isinstance(item['value'], str):
        raise SystemExit(f'Missing or unsuitable non-secret output: {output_name}')
    print(f'export {environment_name}={shlex.quote(item["value"])}')
