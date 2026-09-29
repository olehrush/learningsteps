"""Check CRUD behavior with a disposable journal entry; never delete other data."""
import argparse
import json
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--base-url', required=True)
args = parser.parse_args()
base = args.base_url.rstrip('/')


def request(method, path, payload=None, expected=200):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    allowed = (expected,) if isinstance(expected, int) else expected
    if status not in allowed:
        raise AssertionError(f'{method} {path}: expected HTTP {expected}, received {status}')
    return json.loads(body) if body else None


request('GET', '/health/live')
request('GET', '/health/ready')
entry_id = None
try:
    created = request('POST', '/entries', {
        'work': 'Walkthrough smoke test',
        'struggle': 'Verifying database persistence',
        'intention': 'Complete automated deployment',
    })
    entry_id = created['entry']['id']
    fetched = request('GET', f'/entries/{entry_id}')
    assert fetched['work'] == 'Walkthrough smoke test'
    listed = request('GET', '/entries')
    assert any(item['id'] == entry_id for item in listed['entries'])
    request('PATCH', f'/entries/{entry_id}', {'work': 'Updated smoke test'})
    updated = request('GET', f'/entries/{entry_id}')
    assert updated['work'] == 'Updated smoke test'
    assert updated['struggle'] == 'Verifying database persistence'
    request('DELETE', f'/entries/{entry_id}')
    request('GET', f'/entries/{entry_id}', expected=404)
    entry_id = None
finally:
    if entry_id:
        request('DELETE', f'/entries/{entry_id}', expected=(200, 404))
print('PASS: health, create, list, get, partial update, delete and missing-entry behavior.')
