import enum
import uuid
from datetime import date, datetime
from typing import List, Optional

from sqlalchemy import UUID, String, Enum, Date, DateTime, Text, ForeignKey
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass

class ProjectCategory(str, enum.Enum):
    B2G = "b2g"
    B2B = "b2b"
    B2D = "b2d"


class ProjectStatus(str, enum.Enum):
    ACTIVE = "active"
    COMPLETED = "completed"
    ON_HOLD = "on_hold"


class ToolStatus(str, enum.Enum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"


# ---------- Models ----------
class Admin(Base):
    __tablename__ = "admins"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(200), nullable=False)
    hashed_password: Mapped[str] = mapped_column(String(200), nullable=False)


class Country(Base):
    __tablename__ = "countries"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(100), nullable=False, unique=True)
    code: Mapped[Optional[str]] = mapped_column(String(3))

    projects: Mapped[List["Project"]] = relationship(
        secondary="project_countries", back_populates="countries"
    )


class Employee(Base):
    __tablename__ = "employees"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    email: Mapped[str] = mapped_column(String(200), nullable=False, unique=True)
    position: Mapped[Optional[str]] = mapped_column(String(200))

    managed_projects: Mapped[List["Project"]] = relationship(back_populates="project_manager")
    team_projects: Mapped[List["Project"]] = relationship(
        secondary="project_team_members", back_populates="team_members"
    )
    requested_tools: Mapped[List["Tool"]] = relationship(back_populates="requested_by")


class Partner(Base):
    __tablename__ = "partners"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(200), nullable=False, unique=True)
    partner_type: Mapped[Optional[str]] = mapped_column(String(100))

    projects: Mapped[List["Project"]] = relationship(
        secondary="project_partners", back_populates="projects"
    )


class Project(Base):
    __tablename__ = "projects"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    category: Mapped[ProjectCategory] = mapped_column(
        Enum(ProjectCategory, name="projectcategory", values_callable=lambda x: [e.value for e in x]),
        nullable=False
    )
    description: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[ProjectStatus] = mapped_column(
        Enum(ProjectStatus, name="projectstatus", values_callable=lambda x: [e.value for e in x]),
        nullable=False
    )
    start_date: Mapped[Optional[date]] = mapped_column(Date)
    end_date: Mapped[Optional[date]] = mapped_column(Date)
    created_at: Mapped[Optional[datetime]] = mapped_column(DateTime)
    content: Mapped[Optional[str]] = mapped_column(Text)
    project_manager_id: Mapped[Optional[uuid.UUID]] = mapped_column(ForeignKey("employees.id"))

    project_manager: Mapped[Optional[Employee]] = relationship(back_populates="managed_projects")
    countries: Mapped[List[Country]] = relationship(
        secondary="project_countries", back_populates="projects"
    )
    partners: Mapped[List[Partner]] = relationship(
        secondary="project_partners", back_populates="projects"
    )
    team_members: Mapped[List[Employee]] = relationship(
        secondary="project_team_members", back_populates="team_projects"
    )
    tools: Mapped[List["Tool"]] = relationship(back_populates="project")


class Tool(Base):
    __tablename__ = "tools"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    category: Mapped[str] = mapped_column(String(100), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    owner_team: Mapped[Optional[str]] = mapped_column(String(200))
    access_instructions: Mapped[Optional[str]] = mapped_column(Text)
    status: Mapped[ToolStatus] = mapped_column(
        Enum(ToolStatus, name="toolstatus", values_callable=lambda x: [e.value for e in x]),
        nullable=False
    )
    created_at: Mapped[Optional[datetime]] = mapped_column(DateTime)
    project_id: Mapped[Optional[uuid.UUID]] = mapped_column(ForeignKey("projects.id"))
    requested_by_id: Mapped[Optional[uuid.UUID]] = mapped_column(ForeignKey("employees.id"))

    project: Mapped[Optional[Project]] = relationship(back_populates="tools")
    requested_by: Mapped[Optional[Employee]] = relationship(back_populates="requested_tools")


# ---------- Association / link tables ----------
class ProjectCountry(Base):
    __tablename__ = "project_countries"

    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id"), primary_key=True)
    country_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("countries.id"), primary_key=True)


class ProjectTeamMember(Base):
    __tablename__ = "project_team_members"

    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id"), primary_key=True)
    employee_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("employees.id"), primary_key=True)


class ProjectPartner(Base):
    __tablename__ = "project_partners"

    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id"), primary_key=True)
    partner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("partners.id"), primary_key=True)
