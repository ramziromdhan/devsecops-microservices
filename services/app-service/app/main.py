from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import create_engine, Column, Integer, String, DateTime, Text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from jose import JWTError, jwt
from datetime import datetime
from pydantic import BaseModel
import os, socket, time
from prometheus_fastapi_instrumentator import Instrumentator

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://appuser:apppass@app-db:5432/appdb")
SECRET_KEY   = os.getenv("JWT_SECRET_KEY", "changeme-in-production-use-vault")
ALGORITHM    = "HS256"

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()

class Item(Base):
    __tablename__ = "items"
    id          = Column(Integer, primary_key=True, index=True)
    title       = Column(String, index=True)
    description = Column(Text)
    owner_email = Column(String, index=True)
    created_at  = Column(DateTime, default=datetime.utcnow)

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="http://auth-service/auth/token")

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_current_user_email(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email = payload.get("sub")
        if not email:
            raise HTTPException(status_code=401, detail="Invalid token")
        return email
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

class ItemCreate(BaseModel):
    title: str
    description: str

# 1. Déclaration de l'application FastAPI
app = FastAPI(title="App Service", version="1.0.0")

# Prometheus metrics endpoint
Instrumentator().instrument(app).expose(app)

# 2. Événement de démarrage avec boucle de retry (15 x 5s = 75s de tolérance)
@app.on_event("startup")
def startup():
    max_retries = 15
    for attempt in range(max_retries):
        try:
            Base.metadata.create_all(bind=engine)
            print(f"✅ Database connected on attempt {attempt + 1}")
            return
        except Exception as e:
            print(f"⏳ DB not ready ({attempt + 1}/{max_retries}): {e}")
            time.sleep(5)
    raise RuntimeError("❌ Could not connect to database")

# 3. Middlewares
@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"]         = "DENY"
    response.headers["X-XSS-Protection"]        = "1; mode=block"
    return response

# 4. Routes
@app.get("/items")
def list_items(
    db: Session = Depends(get_db),
    email: str = Depends(get_current_user_email)
):
    return db.query(Item).filter(Item.owner_email == email).all()

@app.post("/items", status_code=201)
def create_item(
    item: ItemCreate,
    db: Session = Depends(get_db),
    email: str = Depends(get_current_user_email)
):
    db_item = Item(title=item.title, description=item.description, owner_email=email)
    db.add(db_item)
    db.commit()
    db.refresh(db_item)
    return db_item

@app.delete("/items/{item_id}")
def delete_item(
    item_id: int,
    db: Session = Depends(get_db),
    email: str = Depends(get_current_user_email)
):
    item = db.query(Item).filter(Item.id == item_id, Item.owner_email == email).first()
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    db.delete(item)
    db.commit()
    return {"message": "deleted"}

@app.get("/health")
def health():
    return {"status": "ok", "service": "app-service", "host": socket.gethostname()}