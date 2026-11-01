import hashlib
import hmac
import secrets

# PIN hashes are synced to devices so staff can log in while offline.
# The Flutter app re-implements exactly this (lib/util/pin_hash.dart); keep both in step.
PIN_ITERATIONS = 20000


def hash_pin(pin: str, salt: str | None = None) -> tuple[str, str]:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt.encode(), PIN_ITERATIONS)
    return salt, digest.hex()


def verify_pin(pin: str, salt: str, pin_hash: str) -> bool:
    return hmac.compare_digest(hash_pin(pin, salt)[1], pin_hash)


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260000)
    return f"pbkdf2${salt}${digest.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored or not stored.startswith("pbkdf2$"):
        return False
    _, salt, digest = stored.split("$", 2)
    calc = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260000).hex()
    return hmac.compare_digest(calc, digest)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_pairing_code() -> str:
    return f"{secrets.randbelow(1000000):06d}"
