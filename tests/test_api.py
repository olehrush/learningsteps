"""Exercise routes and the real service against isolated in-memory data."""

from copy import deepcopy

from fastapi.testclient import TestClient
import pytest

import main
from routers.journal_router import get_entry_service
from services.entry_service import EntryService


class FakeRepository:
    """Storage test double; preserves the repository's async interface."""

    def __init__(self):
        self.entries = {}

    async def create_entry(self, entry):
        self.entries[entry["id"]] = deepcopy(entry)
        return deepcopy(entry)

    async def get_all_entries(self):
        return deepcopy(list(self.entries.values()))

    async def get_entry(self, entry_id):
        return deepcopy(self.entries.get(entry_id))

    async def update_entry(self, entry_id, entry):
        self.entries[entry_id] = deepcopy(entry)

    async def delete_entry(self, entry_id):
        self.entries.pop(entry_id, None)

    async def delete_all_entries(self):
        self.entries.clear()


@pytest.fixture
def payload():
    return {
        "work": "Learning Docker",
        "struggle": "Understanding images and containers",
        "intention": "Deploy LearningSteps on Azure",
    }


@pytest.fixture
def service():
    # Exercise the real service logic, including merge behavior for PATCH.
    return EntryService(FakeRepository())


@pytest.fixture
def client(service):
    async def override_service():
        yield service

    main.app.dependency_overrides[get_entry_service] = override_service
    try:
        with TestClient(main.app) as test_client:
            yield test_client
    finally:
        main.app.dependency_overrides.clear()


def test_create_list_and_get_entry(client, payload):
    response = client.post("/entries", json=payload)
    assert response.status_code == 200
    entry = response.json()["entry"]
    assert entry["id"]
    assert entry["created_at"]
    for field, value in payload.items():
        assert entry[field] == value

    listing = client.get("/entries")
    assert listing.status_code == 200
    assert listing.json() == {"entries": [entry], "count": 1}

    result = client.get(f"/entries/{entry['id']}")
    assert result.status_code == 200
    assert result.json() == entry


def test_partial_update_preserves_other_fields(client, payload):
    original = client.post("/entries", json=payload).json()["entry"]
    path = f"/entries/{original['id']}"

    result = client.patch(path, json={"work": "Tested the Docker image"})
    assert result.status_code == 200
    updated = result.json()
    assert updated["work"] == "Tested the Docker image"
    assert updated["struggle"] == original["struggle"]
    assert updated["intention"] == original["intention"]
    assert updated["id"] == original["id"]
    assert updated["created_at"] == original["created_at"]
    assert updated["updated_at"] >= original["updated_at"]
    assert client.get(path).json() == updated


def test_delete_entry_and_then_return_404(client, payload):
    entry = client.post("/entries", json=payload).json()["entry"]
    path = f"/entries/{entry['id']}"

    assert client.delete(path).status_code == 200
    assert client.get(path).status_code == 404
    assert client.delete(path).status_code == 404
    assert client.get("/entries").json() == {"entries": [], "count": 0}


@pytest.mark.parametrize("method", ["get", "patch", "delete"])
def test_missing_entry_returns_404(client, method):
    kwargs = {"json": {"work": "Updated"}} if method == "patch" else {}
    response = getattr(client, method)("/entries/missing-id", **kwargs)
    assert response.status_code == 404
    assert response.json()["detail"] == "Entry not found"


def test_delete_all_is_limited_to_test_storage(client, payload):
    client.post("/entries", json=payload)
    client.post("/entries", json=payload)
    assert client.get("/entries").json()["count"] == 2
    assert client.delete("/entries").status_code == 200
    assert client.get("/entries").json()["count"] == 0


@pytest.mark.parametrize("field", ["work", "struggle", "intention"])
def test_create_rejects_overlong_content(client, payload, field):
    payload[field] = "x" * 257
    assert client.post("/entries", json=payload).status_code == 422
    assert client.get("/entries").json()["count"] == 0


def test_create_rejects_missing_required_field(client, payload):
    del payload["intention"]
    assert client.post("/entries", json=payload).status_code == 422


def test_create_reports_storage_failure(client, service, payload, monkeypatch):
    async def broken_create(_entry):
        raise RuntimeError("Test storage is unavailable")

    monkeypatch.setattr(service.db, "create_entry", broken_create)
    assert client.post("/entries", json=payload).status_code == 400


def test_root_redirects_to_swagger(client):
    response = client.get("/", follow_redirects=False)
    assert response.status_code == 307
    assert response.headers["location"] == "/docs"
    assert client.get("/docs").status_code == 200


def test_liveness_does_not_require_database(client, monkeypatch):
    async def unavailable():
        raise AssertionError("Liveness must not query the database")

    monkeypatch.setattr(main, "check_database", unavailable)
    response = client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_succeeds_after_database_check(client, monkeypatch):
    checks = []

    async def available():
        checks.append(True)

    monkeypatch.setattr(main, "check_database", available)
    response = client.get("/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert checks == [True]


@pytest.mark.parametrize("failure", [ConnectionError, TimeoutError])
def test_readiness_reports_failure_without_connection_details(
    client, monkeypatch, failure
):
    async def unavailable():
        raise failure("Private connection detail must stay out of the response")

    monkeypatch.setattr(main, "check_database", unavailable)
    response = client.get("/health/ready")
    assert response.status_code == 503
    assert response.json() == {"detail": "Database unavailable"}
