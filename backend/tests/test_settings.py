import pytest
from pydantic import ValidationError

from app.settings import DatabaseSettings


def test_password_is_required_and_not_exposed_in_validation_errors(monkeypatch):
    monkeypatch.delenv("DB_PASSWORD", raising=False)
    with pytest.raises(ValidationError):
        DatabaseSettings.from_environment()

    secret_value = "configuration-test-only"
    with pytest.raises(ValidationError) as failure:
        DatabaseSettings(password=secret_value, port=0)
    assert secret_value not in str(failure.value)


def test_database_url_preserves_password_characters():
    password_value = "local-test:@/+$% value"
    settings = DatabaseSettings(password=password_value)
    assert settings.url.password == password_value
    assert password_value not in repr(settings)
    assert password_value not in str(settings.url)
