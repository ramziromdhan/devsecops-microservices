from fastapi import FastAPI, UploadFile, File, Depends, HTTPException, Request
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
import os, socket, hashlib, subprocess, tempfile
from prometheus_fastapi_instrumentator import Instrumentator

SECRET_KEY = os.getenv("JWT_SECRET_KEY", "changeme-in-production-use-vault")
ALGORITHM  = "HS256"
UPLOAD_DIR = "/tmp/uploads"
MAX_SIZE   = 10 * 1024 * 1024  # 10MB

os.makedirs(UPLOAD_DIR, exist_ok=True)

ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".txt", ".csv"}
ALLOWED_MIMETYPES  = {"application/pdf", "image/png", "image/jpeg", "text/plain", "text/csv"}

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="http://auth-service/auth/token")

def get_current_user_email(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email = payload.get("sub")
        if not email:
            raise HTTPException(status_code=401, detail="Invalid token")
        return email
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

app = FastAPI(title="File Service", version="1.0.0")

# . Lancer l'instrumentation et exposer le endpoint /metrics
Instrumentator().instrument(app).expose(app)

@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"]         = "DENY"
    return response

@app.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    email: str = Depends(get_current_user_email)
):
    # Vérification taille
    contents = await file.read()
    if len(contents) > MAX_SIZE:
        raise HTTPException(status_code=413, detail="File too large")

    # Vérification extension
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Extension {ext} not allowed")

    # Vérification Content-Type
    if file.content_type not in ALLOWED_MIMETYPES:
        raise HTTPException(status_code=400, detail="MIME type not allowed")

    # Path traversal protection — ne jamais utiliser le nom de fichier original
    file_hash = hashlib.sha256(contents).hexdigest()
    safe_filename = f"{file_hash}{ext}"
    safe_path = os.path.join(UPLOAD_DIR, safe_filename)

    # Écriture sécurisée
    with open(safe_path, "wb") as f:
        f.write(contents)

    return {
        "filename": safe_filename,
        "size": len(contents),
        "hash": file_hash,
        "uploaded_by": email
    }

@app.get("/health")
def health():
    return {"status": "ok", "service": "file-service", "host": socket.gethostname()}