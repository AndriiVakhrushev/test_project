"""Add role to user

Revision ID: b7c2a9f31d4e
Revises: fe56fa70289e
Create Date: 2026-08-28 12:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b7c2a9f31d4e'
down_revision = 'fe56fa70289e'
branch_labels = None
depends_on = None


def upgrade():
    # Create the role enum type first, then add the column using it.
    role_enum = sa.Enum('admin', 'manager', 'member', name='role')
    role_enum.create(op.get_bind(), checkfirst=True)
    op.add_column(
        'user',
        sa.Column(
            'role',
            role_enum,
            server_default='member',
            nullable=False,
        ),
    )
    # Backfill: existing superusers become admins, everyone else a member.
    op.execute("UPDATE \"user\" SET role = 'admin' WHERE is_superuser = true")
    op.execute("ALTER TABLE \"user\" ALTER COLUMN role DROP DEFAULT")


def downgrade():
    op.drop_column('user', 'role')
    role_enum = sa.Enum('admin', 'manager', 'member', name='role')
    role_enum.drop(op.get_bind(), checkfirst=True)
