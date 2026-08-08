#!/bin/bash
cd ~/Projects/devsecops-microservices
source .venv/bin/activate 2>/dev/null || true

echo "=== Daily Security Sync — $(date) ==="

# 1. Exporter les rapports Trivy Operator (cluster live)
./monitoring/defectdojo/export-trivy-operator.sh

# 2. Importer les rapports CI/CD (derniers artefacts)
./monitoring/defectdojo/import-reports.sh

echo "=== Sync terminé ==="
