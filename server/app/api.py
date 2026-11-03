"""JSON API used by the PDA devices."""
from datetime import timedelta

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import services
from .db import get_db
from .models import Device, now
from .security import hash_token, new_token

router = APIRouter(prefix="/api/v1")


class PairIn(BaseModel):
    code: str = Field(min_length=6, max_length=12)
    app_version: str | None = None


def current_device(authorization: str = Header(default=""), db: Session = Depends(get_db)) -> Device:
    token = authorization.removeprefix("Bearer ").strip()
    device = db.scalar(select(Device).where(Device.token_hash == hash_token(token))) if token else None
    if not device or not device.active:
        raise HTTPException(401, "device_not_paired")
    seen = now()
    if not device.last_seen or seen - device.last_seen > timedelta(seconds=30):
        device.last_seen = seen
        db.commit()
    services.set_actor(db, f"dev:{device.id}")  # the audit log records changes made by this upload
    return device


@router.get("/ping")
def ping():
    return {"ok": True, "app": "tamween", "server_time": now().isoformat()}


@router.post("/pair")
def pair(body: PairIn, db: Session = Depends(get_db)):
    device = db.scalar(select(Device).where(Device.pairing_code == body.code.strip(), Device.active.is_(True)))
    if not device or not device.pairing_expires or device.pairing_expires < now():
        raise HTTPException(400, "bad_code")
    token = new_token()
    device.token_hash = hash_token(token)
    device.pairing_code = None
    device.pairing_expires = None
    device.paired_at = now()
    device.last_seen = now()
    device.app_version = body.app_version
    db.commit()
    return {"token": token, "device_id": device.id, "device_name": device.name}


@router.get("/sync/pull")
def sync_pull(since: int = 0, device: Device = Depends(current_device), db: Session = Depends(get_db)):
    return services.pull(db, max(0, since), device)


@router.post("/sync/push")
def sync_push(payload: dict, device: Device = Depends(current_device), db: Session = Depends(get_db)):
    return services.push(db, device, payload)
