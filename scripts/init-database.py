"""Initialize private Azure PostgreSQL through a temporary, operator-run AKS Job.

Requires operator az login, kubectl access and KEY_VAULT_NAME. Secret values are
passed on stdin to kubectl, never printed or written to a local file.
"""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
from urllib.parse import unquote, urlparse

vault = os.environ.get('KEY_VAULT_NAME')
if not vault:
    raise SystemExit('Set KEY_VAULT_NAME from Terraform outputs first.')
namespace = 'learningsteps'
suffix = secrets.token_hex(4)
name = f'learningsteps-db-init-{suffix}'


def secret_value(secret_name):
    return subprocess.check_output([
        'az', 'keyvault', 'secret', 'show', '--vault-name', vault,
        '--name', secret_name, '--query', 'value', '-o', 'tsv', '--only-show-errors',
    ], text=True).strip()


def apply(obj):
    subprocess.run(['kubectl', 'apply', '-f', '-'],
                   input=json.dumps(obj), text=True, check=True, stdout=subprocess.DEVNULL)


admin_url = secret_value('DATABASE-ADMIN-URL')
application_url = secret_value('DATABASE-URL')
parsed = urlparse(application_url)
app_user = unquote(parsed.username or '')
app_password = unquote(parsed.password or '')
database_name = unquote(parsed.path.lstrip('/'))
if not all((app_user, app_password, database_name)):
    raise SystemExit('Application database secret is incomplete.')

schema = '\n'.join(
    line for line in Path('database_setup.sql').read_text().splitlines()
    if not line.lstrip().startswith('\\d ')
) + '\n'
grant_sql = '''
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user')
\\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
\\gexec
GRANT CONNECT ON DATABASE :"db_name" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.entries TO :"app_user";
'''

secret = {
    'apiVersion': 'v1', 'kind': 'Secret',
    'metadata': {'name': name, 'namespace': namespace}, 'type': 'Opaque',
    'data': {key: base64.b64encode(value.encode()).decode() for key, value in {
        'ADMIN_URL': admin_url, 'APP_USER': app_user,
        'APP_PASSWORD': app_password, 'DB_NAME': database_name,
    }.items()},
}
config = {
    'apiVersion': 'v1', 'kind': 'ConfigMap',
    'metadata': {'name': name, 'namespace': namespace},
    'data': {'setup.sql': schema + '\n' + grant_sql},
}
job = {
    'apiVersion': 'batch/v1', 'kind': 'Job',
    'metadata': {'name': name, 'namespace': namespace},
    'spec': {
        'backoffLimit': 0, 'activeDeadlineSeconds': 240, 'ttlSecondsAfterFinished': 300,
        'template': {'spec': {
            'restartPolicy': 'Never', 'automountServiceAccountToken': False,
            'securityContext': {'runAsNonRoot': True, 'runAsUser': 70,
                                'runAsGroup': 70, 'seccompProfile': {'type': 'RuntimeDefault'}},
            'containers': [{
                'name': 'setup', 'image': 'postgres:16.15-alpine3.23',
                'envFrom': [{'secretRef': {'name': name}}],
                'command': ['/bin/sh', '-ec'],
                'args': ['psql "$ADMIN_URL" -X --set=ON_ERROR_STOP=1 '
                         '--set=app_user="$APP_USER" --set=app_password="$APP_PASSWORD" '
                         '--set=db_name="$DB_NAME" --file=/setup/setup.sql'],
                'securityContext': {'allowPrivilegeEscalation': False,
                                    'capabilities': {'drop': ['ALL']}},
                'resources': {'requests': {'cpu': '100m', 'memory': '128Mi'},
                              'limits': {'cpu': '500m', 'memory': '256Mi'}},
                'volumeMounts': [{'name': 'setup', 'mountPath': '/setup', 'readOnly': True}],
            }],
            'volumes': [{'name': 'setup', 'configMap': {'name': name}}],
        }},
    },
}

try:
    apply(secret)
    apply(config)
    apply(job)
    print(f'Running database initialization Job {name} in namespace {namespace}.')
    subprocess.run(['kubectl', '-n', namespace, 'wait', '--for=condition=complete',
                    f'job/{name}', '--timeout=250s'], check=True)
    print('Database schema and restricted application role are ready.')
except subprocess.CalledProcessError:
    print('Initialization failed. Check private DNS, network access, TLS and PostgreSQL status.')
    print('Temporary credentials will be removed; fix the cause and rerun this helper.')
    raise SystemExit(1)
finally:
    subprocess.run(['kubectl', '-n', namespace, 'delete', 'job,secret,configmap', name,
                    '--ignore-not-found=true', '--wait=false'], check=False,
                   stdout=subprocess.DEVNULL)
