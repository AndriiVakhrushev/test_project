"""Create (or update) a user with a given email, role, and password.

Usage (from the backend directory):

    uv run python -m app.create_user --email manager@example.com --role manager
    uv run python -m app.create_user --email admin@example.com --role admin --password s3cret
    uv run python -m app.create_user --email member@example.com

If the user already exists, their role is updated and, when a password is given,
the password is reset too. Otherwise the user is created with that role.

Note: role is the source of truth for RBAC. Assigning the 'admin' role also sets
the user's is_superuser flag to True (and clears it for other roles).
"""

import argparse
import logging
from getpass import getpass

from sqlmodel import Session, select

from app import crud
from app.core.db import engine
from app.models import Role, User, UserCreate, UserUpdate

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

ROLES = {role.value for role in Role}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create or update a user with a role.")
    parser.add_argument("--email", required=True, help="Email address of the user.")
    parser.add_argument(
        "--role",
        choices=sorted(ROLES),
        default="member",
        help="Role to assign. Defaults to 'member'.",
    )
    parser.add_argument(
        "--password",
        default=None,
        help="Password (min 8 chars). Prompted for if omitted.",
    )
    args = parser.parse_args()
    if args.password is None:
        args.password = getpass("Password: ")
    return args


def create_or_update_user(
    *, session: Session, email: str, role: Role, password: str
) -> User:
    existing = session.exec(select(User).where(User.email == email)).first()
    if existing:
        user_in = UserUpdate(
            role=role,
            **( {"password": password} if password else {}),
        )
        return crud.update_user(  # type: ignore[no-any-return]
            session=session, db_user=existing, user_in=user_in
        )
    return crud.create_user(
        session=session,
        user_create=UserCreate(email=email, password=password, role=role),
    )


def main() -> None:
    args = _parse_args()
    with Session(engine) as session:
        user = create_or_update_user(
            session=session,
            email=args.email,
            role=Role(args.role),
            password=args.password,
        )
    logger.info("User %s is now role=%s", user.email, user.role)


if __name__ == "__main__":
    main()
