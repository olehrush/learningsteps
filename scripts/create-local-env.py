"""Create local-only credentials. Existing files are never overwritten."""
from pathlib import Path
import secrets

target = Path('.env.local')
password = secrets.token_urlsafe(24)
with target.open('x', encoding='utf-8') as output:
    output.write(
        'POSTGRES_USER=learningsteps_local\n'
        f'POSTGRES_PASSWORD={password}\n'
        'POSTGRES_DB=learning_journal\n'
        f'DATABASE_URL=postgresql://learningsteps_local:{password}'
        '@postgres:5432/learning_journal\n'
    )
target.chmod(0o600)
print('Created .env.local. Keep this file out of Git.')
