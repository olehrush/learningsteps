"""Render non-secret deployment settings; no third-party modules are needed."""
from pathlib import Path
from string import Template
import os
import re

required = ('IMAGE_REF', 'AZURE_TENANT_ID', 'KEY_VAULT_NAME', 'WORKLOAD_CLIENT_ID')
settings = {}
for name in required:
    value = os.environ.get(name, '')
    if not value or not re.fullmatch(r'[A-Za-z0-9._:/@-]+', value):
        raise SystemExit(f'Missing or invalid {name}; set the non-secret environment variable.')
    settings[name] = value
destination = Path('k8s-rendered')
destination.mkdir(exist_ok=True)
for name in ('bootstrap', 'app'):
    source = Path('k8s-manifests') / f'{name}.yaml.tmpl'
    result = Template(source.read_text()).substitute(settings)
    (destination / f'{name}.yaml').write_text(result)
print('Rendered k8s-rendered/bootstrap.yaml and k8s-rendered/app.yaml.')
