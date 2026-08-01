FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf AS runtime

RUN useradd --no-create-home --uid 1001 appuser
WORKDIR /app

# Le file-service a besoin des droits pour écrire dans le dossier d'upload
RUN mkdir -p /tmp/uploads && chown appuser:appuser /tmp/uploads

COPY --from=builder /install /usr/local
COPY app/ .
USER appuser
EXPOSE 8003
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8003"]