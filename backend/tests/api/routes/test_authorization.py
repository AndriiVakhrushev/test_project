from unittest.mock import patch

from fastapi.testclient import TestClient
from sqlmodel import Session

from app import crud
from app.core.config import settings
from app.models import Role, UserCreate
from tests.utils.user import create_random_user
from tests.utils.utils import random_email, random_lower_string

# The permission matrix under test:
#                         admin   manager   member
# List all users             ✓        ✓        ✗
# Create user                ✓        ✗        ✗
# View metrics               ✓        ✓        ✗
# Update own profile         ✓        ✓        ✓
# Update any profile         ✓        ✗        ✗

FORBIDDEN_DETAIL = "The user doesn't have enough privileges"


def _expect_allowed(response) -> None:
    assert 200 <= response.status_code < 300


def _expect_forbidden(response) -> None:
    assert response.status_code == 403
    assert response.json()["detail"] == FORBIDDEN_DETAIL


def test_admin_can_list_users(
    client: TestClient, superuser_token_headers: dict[str, str]
) -> None:
    _expect_allowed(
        client.get(f"{settings.API_V1_STR}/users/", headers=superuser_token_headers)
    )


def test_manager_can_list_users(
    client: TestClient, manager_user: dict[str, str]
) -> None:
    _expect_allowed(client.get(f"{settings.API_V1_STR}/users/", headers=manager_user))


def test_member_cannot_list_users(
    client: TestClient, normal_user_token_headers: dict[str, str]
) -> None:
    _expect_forbidden(
        client.get(f"{settings.API_V1_STR}/users/", headers=normal_user_token_headers)
    )


def test_admin_can_create_user(
    client: TestClient, superuser_token_headers: dict[str, str]
) -> None:
    with (
        patch("app.utils.send_email", return_value=None),
        patch("app.core.config.settings.SMTP_HOST", "smtp.example.com"),
        patch("app.core.config.settings.SMTP_USER", "admin@example.com"),
    ):
        data = {"email": random_email(), "password": random_lower_string()}
        _expect_allowed(
            client.post(
                f"{settings.API_V1_STR}/users/",
                headers=superuser_token_headers,
                json=data,
            )
        )


def test_manager_cannot_create_user(
    client: TestClient, manager_user: dict[str, str]
) -> None:
    data = {"email": random_email(), "password": random_lower_string()}
    _expect_forbidden(
        client.post(f"{settings.API_V1_STR}/users/", headers=manager_user, json=data)
    )


def test_member_cannot_create_user(
    client: TestClient, normal_user_token_headers: dict[str, str]
) -> None:
    data = {"email": random_email(), "password": random_lower_string()}
    _expect_forbidden(
        client.post(
            f"{settings.API_V1_STR}/users/",
            headers=normal_user_token_headers,
            json=data,
        )
    )


def test_admin_can_view_metrics(
    client: TestClient, superuser_token_headers: dict[str, str]
) -> None:
    _expect_allowed(
        client.get(f"{settings.API_V1_STR}/metrics/", headers=superuser_token_headers)
    )


def test_manager_can_view_metrics(
    client: TestClient, manager_user: dict[str, str]
) -> None:
    _expect_allowed(
        client.get(f"{settings.API_V1_STR}/metrics/", headers=manager_user)
    )


def test_member_cannot_view_metrics(
    client: TestClient, normal_user_token_headers: dict[str, str]
) -> None:
    _expect_forbidden(
        client.get(f"{settings.API_V1_STR}/metrics/", headers=normal_user_token_headers)
    )


def test_member_can_update_own_profile(
    client: TestClient, normal_user_token_headers: dict[str, str]
) -> None:
    _expect_allowed(
        client.patch(
            f"{settings.API_V1_STR}/users/me",
            headers=normal_user_token_headers,
            json={"full_name": "Member Updated"},
        )
    )


def test_member_cannot_update_any_profile(
    client: TestClient, normal_user_token_headers: dict[str, str], db: Session
) -> None:
    target = create_random_user(db)
    _expect_forbidden(
        client.patch(
            f"{settings.API_V1_STR}/users/{target.id}",
            headers=normal_user_token_headers,
            json={"full_name": "Hacked"},
        )
    )


def test_manager_cannot_update_any_profile(
    client: TestClient, manager_user: dict[str, str], db: Session
) -> None:
    target = create_random_user(db)
    _expect_forbidden(
        client.patch(
            f"{settings.API_V1_STR}/users/{target.id}",
            headers=manager_user,
            json={"full_name": "Hacked"},
        )
    )


def test_admin_can_update_any_profile(
    client: TestClient, superuser_token_headers: dict[str, str], db: Session
) -> None:
    target = create_random_user(db)
    _expect_allowed(
        client.patch(
            f"{settings.API_V1_STR}/users/{target.id}",
            headers=superuser_token_headers,
            json={"full_name": "Admin Updated"},
        )
    )


def test_new_users_default_to_member_role(db: Session) -> None:
    email = random_email()
    crud.create_user(
        session=db, user_create=UserCreate(email=email, password=random_lower_string())
    )
    user = crud.get_user_by_email(session=db, email=email)
    assert user is not None
    assert user.role == Role.member
