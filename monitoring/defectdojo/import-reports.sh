#!/bin/bash
set -e

# Charger la configuration DefectDojo
source monitoring/defectdojo/.dd-config

echo "========================================================"
echo "  DefectDojo Import — $(date)"
echo "  URL: $DD_URL | Product: $PRODUCT_NAME"
echo "========================================================"

IMPORTED=0
FAILED=0

import_scan() {
    local name=$1
    local file=$2
    local scanner=$3

    if [ ! -f "$file" ]; then
        echo "  ⚠️  $name → fichier manquant: $file"
        return
    fi

    RESPONSE=$(curl -s -X POST "$DD_URL/api/v2/import-scan/" \
        -H "Authorization: Token $DD_TOKEN" \
        -F "scan_type=$scanner" \
        -F "file=@$file" \
        -F "product_name=$PRODUCT_NAME" \
        -F "engagement_name=CI/CD Scans" \
        -F "auto_create_context=true" \
        -F "active=true" \
        -F "verified=false" \
        -F "close_old_findings=true" \
        -F "minimum_severity=Low")

    # Extraire le nombre de findings créés
    CREATED=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('statistics', {}).get('created', d.get('test', {}).get('id', '?')))
except Exception:
    print('error')
" 2>/dev/null)

    if echo "$RESPONSE" | grep -q '"test"'; then
        echo "  ✅ $name → importé (findings: $CREATED)"
        IMPORTED=$((IMPORTED+1))
    else
        echo "  ❌ $name → erreur: $(echo "$RESPONSE" | head -c 200)"
        FAILED=$((FAILED+1))
    fi
}

echo ""
echo "--- SAST ---"
import_scan "Bandit" \
    "tests/security/results/bandit-report.json" \
    "Bandit Scan"

import_scan "Semgrep" \
    "tests/security/results/semgrep-report.json" \
    "Semgrep JSON Report"

echo ""
echo "--- SCA ---"
import_scan "Trivy (auth-service)" \
    "tests/security/results/trivy-auth-service.json" \
    "Trivy Scan"

import_scan "Trivy (app-service)" \
    "tests/security/results/trivy-app-service.json" \
    "Trivy Scan"

import_scan "Trivy (file-service)" \
    "tests/security/results/trivy-file-service.json" \
    "Trivy Scan"

echo ""
echo "--- DAST ---"
import_scan "ZAP Baseline" \
    "tests/security/results/zap/zap-authenticated-report.json" \
    "ZAP Scan"

echo ""
echo "========================================================"
echo "  ✅ Importés : $IMPORTED"
echo "  ❌ Échoués  : $FAILED"
echo "========================================================"

# Récupération dynamique du PRODUCT_ID via l'API DefectDojo à partir du PRODUCT_NAME
PRODUCT_ID=$(curl -s "$DD_URL/api/v2/products/?name=$(echo "$PRODUCT_NAME" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')" \
    -H "Authorization: Token $DD_TOKEN" \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    if results:
        print(results[0]['id'])
    else:
        print('')
except Exception:
    print('')
")

# Afficher le résumé des findings si l'ID a bien été trouvé
if [ -n "$PRODUCT_ID" ]; then
    echo ""
    echo "--- Findings dans DefectDojo ---"
    curl -s "$DD_URL/api/v2/findings/?product=$PRODUCT_ID&limit=200" \
        -H "Authorization: Token $DD_TOKEN" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = data.get('count', 0)
findings = data.get('results', [])
severities = {}
for f in findings:
    sev = f.get('severity', 'Unknown')
    severities[sev] = severities.get(sev, 0) + 1

print(f'Total: {total} findings')
for sev in ['Critical', 'High', 'Medium', 'Low', 'Info']:
    count = severities.get(sev, 0)
    if count > 0:
        symbol = {'Critical':'🔴', 'High':'🟠', 'Medium':'🟡', 'Low':'🔵', 'Info':'⚪'}.get(sev, '•')
        print(f'  {symbol} {sev}: {count}')
"
else
    echo "⚠️ Impossible de récupérer le PRODUCT_ID pour afficher le résumé des findings."
fi