from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_healthz() -> None:
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_chat_rejects_empty_question() -> None:
    response = client.post("/api/chat", json={"question": "   "})

    assert response.status_code == 400
