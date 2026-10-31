# DevSecOps Microservices

An example DevSecOps platform composed of authenticated microservices, PostgreSQL databases, an NGINX API gateway, Kubernetes/Helm deployment manifests, and an automated security pipeline.

The project demonstrates:

- JWT-based authentication and per-user authorization
- CRUD operations for application items
- Secure file upload and object-storage workflows
- Container image scanning, signing, and admission policies
- Kubernetes network policies and RBAC
- Prometheus metrics, Grafana dashboards, and security alerts
- SAST, SCA, DAST, IaC, and DefectDojo reporting

## Architecture

```text
                         +----------------------+
                         |  NGINX API Gateway   |
                         |  :8080 / NodePort    |
                         +----------+-----------+
                                    |
              +---------------------+---------------------+
              |                     |                     |
       +------v------+       +------v------+       +------v------+
       | Auth Service|       | App Service |       | File Service|
       | FastAPI     |       | FastAPI     |       | Python/Go   |
       | :8001       |       | :8002       |       | :8003       |
       +------+------+       +------+------+       +------+------+
              |                     |                     |
       +------v------+       +------v------+       +------v------+
       | Auth DB     |       | App DB      |       | MinIO       |
       | PostgreSQL  |       | PostgreSQL  |       | (Kubernetes)|
       +-------------+       +-------------+       +-------------+
```

### Services

| Component | Local port | Kubernetes role |
|---|---:|---|
| `auth-service` | `8001` | User registration, login, JWT validation |
| `app-service` | `8002` | Authenticated item CRUD |
| `file-service` (Python) | `8003` | Local upload validation and storage |
| `file-service-go` | `8003` | Multipart/presigned upload and MinIO integration |
| `auth-db` | internal | PostgreSQL database for users |
| `app-db` | internal | PostgreSQL database for items |
| `gateway` | `8080` | NGINX routing, headers, and rate limiting |
| MinIO | `9000`/`9001` | Object storage and console in Kubernetes |

The Docker Compose stack builds `services/file-service`. The GitHub Actions and Helm workflows build and deploy `services/file-service-go` as the `file-service` image.

## Prerequisites

For local development:

- Docker Engine with Compose
- `curl`
- Python 3.12 or later for local security tooling

For Kubernetes deployment:

- `kubectl` connected to a cluster
- Helm 3
- A container registry and credentials
- Prometheus Operator if monitoring resources are enabled
- Kyverno if image-policy enforcement is enabled
- Falco if runtime detection is enabled

For the complete security suite, install the tools used by the scripts and pipeline, including `bandit`, `semgrep`, `trivy`, `sqlmap`, `zaproxy`, `checkov`, `kubesec`, `gitleaks`, and `cosign`.

## Quick start with Docker Compose

1. Review the environment values in `docker-compose.yml`. Replace development-only values before using the stack outside a local environment.
2. Start the services:

   ```bash
   docker compose up --build
   ```

3. Check the gateway:

   ```bash
   curl http://localhost:8080/health
   ```

4. Stop the stack:

   ```bash
   docker compose down
   ```

To remove the local database and upload volumes as well:

```bash
docker compose down -v
```

## API usage

The examples below use the gateway at `http://localhost:8080`.

### Register and authenticate

```bash
curl -X POST http://localhost:8080/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"change-this-password"}'

TOKEN=$(curl -s -X POST http://localhost:8080/auth/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=user@example.com&password=change-this-password' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
```

### Current user

```bash
curl http://localhost:8080/auth/me \
  -H "Authorization: Bearer ${TOKEN}"
```

### Items

```bash
curl http://localhost:8080/items \
  -H "Authorization: Bearer ${TOKEN}"

curl -X POST http://localhost:8080/items \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"title":"First item","description":"Example item"}'
```

Items are filtered by the authenticated user. A user cannot read or delete another user's items.

### File upload

The Python file service accepts PDF, PNG, JPEG, TXT, and CSV files up to 10 MiB:

```bash
curl -X POST http://localhost:8080/upload \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'file=@./example.txt'
```

The Go file service provides additional endpoints for multipart/presigned workflows:

```text
POST  /files/initiate
POST  /files/:id/presign-part
POST  /files/:id/complete
POST  /share
GET   /download/:token
PATCH /download/:token/verify
GET   /upload
POST  /upload
```

All protected endpoints require a bearer token. Health endpoints are available at `/health`; Prometheus metrics are exposed at `/metrics` by the application services.

## Kubernetes deployment with Helm

The charts are independent so they can be installed, upgraded, or removed separately. The following example uses the `devsecops-prod` namespace:

```bash
kubectl create namespace devsecops-prod

helm upgrade --install auth-db ./helm/auth-db -n devsecops-prod
helm upgrade --install app-db ./helm/app-db -n devsecops-prod
helm upgrade --install minio ./helm/minio -n devsecops-prod
helm upgrade --install auth-service ./helm/auth-service -n devsecops-prod
helm upgrade --install app-service ./helm/app-service -n devsecops-prod
helm upgrade --install file-service ./helm/file-service -n devsecops-prod
helm upgrade --install gateway ./helm/gateway -n devsecops-prod
helm upgrade --install network-policies ./helm/network-policies -n devsecops-prod
helm upgrade --install rbac ./helm/rbac -n devsecops-prod
```

Inspect the rendered manifests before applying them:

```bash
helm template gateway ./helm/gateway -n devsecops-prod
helm lint ./helm/gateway
```

The gateway chart exposes a NodePort configured in `helm/gateway/values.yaml` (default `30080`). Find the node address and test it with:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
curl "http://${NODE_IP}:30080/health"
```

For OpenShift, the repository also contains route manifests under `openshift/routes/`.

### Image configuration

Update the image repositories and tags in the service chart values before deployment. The CI pipeline publishes images to Quay and uses immutable commit tags in addition to `latest`. Prefer immutable tags in production.

Do not put registry passwords, JWT secrets, MinIO credentials, or signing private keys in Git. Supply them through Kubernetes Secrets, an external secret manager, or CI/CD secret storage.

## Security controls

The repository includes defense-in-depth controls across the application and cluster:

- Password hashing with bcrypt and short-lived JWT access tokens
- Authorization checks on item operations
- Upload size, extension, MIME type, and path-traversal protections
- Security response headers in the services and gateway
- NGINX request-rate limiting
- Non-root and vulnerable-image Kyverno policies
- Cosign image signature verification
- Kubernetes network policies and service accounts
- Falco custom runtime rules
- Trivy vulnerability scanning and CycloneDX SBOM generation

Development defaults are intentionally present in local configuration for convenience. They are not production-safe. Rotate all credentials and set a strong, unique `JWT_SECRET_KEY` before deployment.

## CI/CD pipeline

The workflow in `.github/workflows/pipeline.yml` runs for pushes and pull requests targeting `main`. Its main stages are:

1. **SAST** — Bandit, Semgrep, and Gitleaks
2. **Build** — Build the authentication, application, and Go file-service images
3. **Push** — Publish images to Quay
4. **SCA** — Hadolint, Trivy vulnerability scans, and SBOM generation
5. **Signing** — Sign and verify images with Cosign
6. **IaC validation** — Checkov and Kubernetes manifest scanning
7. **Deployment and verification** — Deploy to the configured Kubernetes environment and run checks

Configure the required GitHub Actions secrets, including registry credentials, Cosign material, and cluster/deployment credentials, in the repository settings. Keep private keys out of workflow files and commits.

## Security testing

The full Kubernetes security suite expects a running deployment, a configured `.env.test`, and the required security tools:

```bash
./tests/security/run-full-security-suite.sh
```

The suite covers:

- Invalid credentials and JWT enforcement
- Per-user data isolation
- Security headers
- File-upload security checks
- SQL injection checks with SQLMap
- Gateway rate limiting

Reports are written under `tests/security/results/` and are intentionally ignored by Git. Run individual checks, such as the SSRF test, only against systems you own or are authorized to assess.

## Monitoring and reporting

Prometheus-compatible metrics are exposed by the services. Kubernetes monitoring resources are in `monitoring/prometheus/`:

- `servicemonitor-microservices.yaml` discovers monitored services
- `alert-rules.yaml` defines authentication-failure, crash-loop, and service-down alerts

The Grafana dashboard is in `monitoring/grafana/dashboards/microservices-security.json`.

DefectDojo integration scripts are in `monitoring/defectdojo/`. Configure the local DefectDojo settings outside Git, then import generated Bandit, Semgrep, Trivy, and ZAP reports:

```bash
./monitoring/defectdojo/import-reports.sh
```

## Repository layout

```text
.
├── .github/workflows/       CI/CD pipeline
├── docker-compose.yml       Local multi-container environment
├── gateway/                 NGINX configuration
├── helm/                    Kubernetes Helm charts
├── kyverno/                Image and workload policies
├── monitoring/              Prometheus, Grafana, and DefectDojo integration
├── openshift/               OpenShift-specific manifests
├── services/
│   ├── auth-service/        FastAPI authentication service
│   ├── app-service/         FastAPI item service
│   ├── file-service/        FastAPI upload service
│   └── file-service-go/     Go/ Gin MinIO-backed file service
├── tests/security/          Security test scripts and generated reports
└── falco/                   Runtime security rules
```

## Development guidelines

- Never commit `.env` files, credentials, private signing keys, certificates, or generated security reports.
- Keep service-specific dependencies in the corresponding service directory.
- Validate Helm changes with `helm lint` and `helm template`.
- Run the relevant security checks after changing authentication, authorization, file handling, gateway rules, or deployment policies.
- Use immutable image tags and external secret management for production deployments.

## License

No license file is currently included in this repository. Add a license before distributing the project.
