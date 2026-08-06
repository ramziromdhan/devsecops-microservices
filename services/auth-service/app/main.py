from fastapi import FastAPI, Depends, HTTPException, status, Request
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.responses import JSONResponse
from sqlalchemy import create_engine, Column, Integer, String, Boolean, DateTime
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from passlib.context import CryptContext
from jose import JWTError, jwt
from datetime import datetime, timedelta
from pydantic import BaseModel, EmailStr
import os, socket, time
from prometheus_fastapi_instrumentator import Instrumentator

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://authuser:authpass@auth-db:5432/authdb")
SECRET_KEY   = os.getenv("JWT_SECRET_KEY", "changeme-in-production-use-vault")
ALGORITHM    = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30


# 1. Déclaration UNIQUE de l'application FastAPI D'ABORD
app = FastAPI(title="Auth Service", version="1.0.0")

# 2. lancer l'instrumentation Prometheus
Instrumentator().instrument(app).expose(app)


engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()

class User(Base):
    __tablename__ = "users"
    id               = Column(Integer, primary_key=True, index=True)
    email            = Column(String, unique=True, index=True)
    hashed_password  = Column(String)
    is_active        = Column(Boolean, default=True)
    created_at       = Column(DateTime, default=datetime.utcnow)



# 2. Gestionnaire de démarrage avec Retry (Seul endroit où create_all est appelé)
@app.on_event("startup")
def startup():
    """Connexion DB avec retry — attend que PostgreSQL soit prêt."""
    max_retries = 15
    for attempt in range(max_retries):
        try:
            Base.metadata.create_all(bind=engine)
            print(f"✅ Database connected on attempt {attempt + 1}")
            return
        except Exception as e:
            print(f"⏳ DB not ready (attempt {attempt + 1}/{max_retries}): {e}")
            time.sleep(5)
    raise RuntimeError("❌ Could not connect to database after multiple retries")

# ── Auth utils ────────────────────────────────────────────────────
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def verify_password(plain, hashed):
    return pwd_context.verify(plain, hashed)

def get_password_hash(password):
    return pwd_context.hash(password)

def create_access_token(data: dict):
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email: str = payload.get("sub")
        if email is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception
    user = db.query(User).filter(User.email == email).first()
    if user is None:
        raise credentials_exception
    return user

# ── Schemas ───────────────────────────────────────────────────────
class UserCreate(BaseModel):
    email: EmailStr
    password: str

class Token(BaseModel):
    access_token: str
    token_type: str

# ── Middleware & Routes ────────────────────────────────────────────
@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"]  = "nosniff"
    response.headers["X-Frame-Options"]          = "DENY"
    response.headers["X-XSS-Protection"]         = "1; mode=block"
    response.headers["Referrer-Policy"]           = "strict-origin-when-cross-origin"
    response.headers["Content-Security-Policy"]   = "default-src 'none'"
    return response

@app.post("/auth/register", status_code=201)
def register(user: UserCreate, db: Session = Depends(get_db)):
    existing = db.query(User).filter(User.email == user.email).first()
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")
    db_user = User(
        email=user.email,
        hashed_password=get_password_hash(user.password)
    )
    db.add(db_user)
    db.commit()
    return {"message": "User created", "email": user.email}

@app.post("/auth/token", response_model=Token)
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == form_data.username).first()
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect credentials"
        )
    token = create_access_token(data={"sub": user.email})
    return {"access_token": token, "token_type": "bearer"}

@app.get("/auth/me")
def get_me(current_user: User = Depends(get_current_user)):
    return {"email": current_user.email, "is_active": current_user.is_active}

@app.get("/health")
def health():
    return {"status": "ok", "service": "auth-service", "host": socket.gethostname()}