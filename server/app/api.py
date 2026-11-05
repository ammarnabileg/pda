"""JSON API used by the PDA devices."""
from datetime import timedelta

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import services
from .db import get_db
from .models import Device, Receipt, now
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


@router.post("/receipt-file")
async def receipt_file(receipt_client_id: str = Form(...), file_id: str = Form(...), file: UploadFile = File(...),
                       device: Device = Depends(current_device), db: Session = Depends(get_db)):
    """Photo of the supplier invoice for a voucher made on this device. Sent after the voucher itself;
    404 means the voucher has not arrived yet, so the device keeps the photo and tries again."""
    r = db.scalar(select(Receipt).where(Receipt.client_id == receipt_client_id, Receipt.device_id == device.id))
    if r is None:
        raise HTTPException(404, "unknown_receipt")
    data = await file.read()
    try:
        f = services.save_receipt_file(db, r, data, file.content_type or "", employee_id=r.received_by,
                                       device_id=device.id, client_id=f"{device.id}:{file_id}"[:60])
    except services.EditError as e:
        raise HTTPException(422, str(e))
    db.commit()
    return {"ok": True, "id": f.id}


@router.post("/products/{pid}/barcodes")
async def product_barcodes(pid: int, request: Request, device: Device = Depends(current_device), db: Session = Depends(get_db)):
    """The barcodes screen on the device: admin only, online only (applied at once, so devices never disagree)."""
    from .models import Employee, Product

    data = await request.json()
    emp = db.get(Employee, int(data.get("employee_id") or 0))
    if emp is None or not emp.active or not emp.is_admin:
        raise HTTPException(403, "admin_only")
    p = db.get(Product, pid)
    if p is None:
        raise HTTPException(404, "unknown_product")
    services.set_actor(db, f"emp:{emp.id}")
    try:
        msg = services.barcode_action(db, p, data)
    except services.EditError as e:
        db.rollback()
        return {"ok": False, "error": str(e)}
    db.commit()
    db.refresh(p)
    return {"ok": True, "msg": msg, "product": services.product_dict(p)}

