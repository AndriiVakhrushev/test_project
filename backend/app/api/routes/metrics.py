from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import func, select

from app.api.deps import SessionDep, require_roles
from app.models import Item, Role, User

router = APIRouter(prefix="/metrics", tags=["metrics"])


class Metrics(BaseModel):
    total_users: int
    total_items: int


@router.get(
    "/",
    dependencies=[Depends(require_roles(Role.admin, Role.manager))],
    response_model=Metrics,
)
def read_metrics(session: SessionDep) -> Any:
    """
    Insights stub: basic aggregate counts for authorized users.
    """
    total_users = session.exec(select(func.count()).select_from(User)).one()
    total_items = session.exec(select(func.count()).select_from(Item)).one()
    return Metrics(total_users=total_users, total_items=total_items)
