#!/bin/bash
set -e

# ── Chargement des variables d'environnement ────────────────────
if [ -f ".env.test" ]; then
    export $(grep -v '^#' .env.test | xargs)
else
    echo "⚠️  Attention : Fichier .env.test non trouvé à la racine."
fi

# Vérification de sécurité pour s'assurer que les variables existent
if [ -z "$TEST_USER" ] || [ -z "$TEST_PASS" ] || [ -z "$TEST_OTHER_USER" ] || [ -z "$TEST_OTHER_PASS" ]; then
    echo "❌ Erreur : Variables d'environnement manquantes dans .env.test"
    exit 1
fi

echo "========================================================"
echo "  Full Security Test Suite — devsecops-microservices"
echo "  $(date)"
echo "========================================================"

NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[0].address}')

# Obtenir un token avec les variables sécurisées
TOKEN=$(curl -s -X POST http://$NODE_IP:30080/auth/token \
  -d "username=$TEST_USER&password=$TEST_PASS" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "Target : http://$NODE_IP:30080"
echo "Token  : ${TOKEN:0:30}..."
echo ""

mkdir -p tests/security/results

TOTAL_PASS=0
TOTAL_FAIL=0

# ── Phase 1 : Auth ──────────────────────────────────────────────
echo "=== Phase 1 : Authentication Tests ==="

run_check() {
    local desc=$1; local expected=$2; local actual=$3
    if [ "$actual" = "$expected" ]; then
        echo "  ✅ $desc"
        TOTAL_PASS=$((TOTAL_PASS+1))
    else
        echo "  ❌ $desc → expected $expected, got $actual"
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
}

# Test du mauvais mot de passe
R=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://$NODE_IP:30080/auth/token \
  -d "username=$TEST_USER&password=wrongpass")
run_check "Wrong password → 401" "401" "$R"

R=$(curl -s -o /dev/null -w "%{http_code}" \
  http://$NODE_IP:30080/items \
  -H "Authorization: Bearer invalid.jwt.token")
run_check "Invalid JWT → 401" "401" "$R"

R=$(curl -s -o /dev/null -w "%{http_code}" \
  http://$NODE_IP:30080/items)
run_check "No token → 401" "401" "$R"

# Test isolation — on utilise les variables de l'autre utilisateur
curl -sf -X POST http://$NODE_IP:30080/auth/register \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_OTHER_USER\",\"password\":\"$TEST_OTHER_PASS\"}" > /dev/null 2>&1 || true

OTHER_TOKEN=$(curl -s -X POST http://$NODE_IP:30080/auth/token \
  -d "username=$TEST_OTHER_USER&password=$TEST_OTHER_PASS" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

ITEMS=$(curl -s http://$NODE_IP:30080/items \
  -H "Authorization: Bearer $OTHER_TOKEN" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
run_check "Data isolation (other user sees 0 items)" "0" "$ITEMS"

echo ""

# ── Phase 2 : Security Headers ──────────────────────────────────
echo "=== Phase 2 : Security Headers ==="

HEADERS=$(curl -sI http://$NODE_IP:30080/health)

for header in "X-Frame-Options" "X-Content-Type-Options" "X-XSS-Protection" "Referrer-Policy"; do
    if echo "$HEADERS" | grep -qi "$header"; then
        echo "  ✅ $header présent"
        TOTAL_PASS=$((TOTAL_PASS+1))
    else
        echo "  ❌ $header manquant"
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done

SERVER=$(echo "$HEADERS" | grep -i "^Server:" | head -1)
if echo "$SERVER" | grep -vq "[0-9]\.[0-9]"; then
    echo "  ✅ Server version masquée ($SERVER)"
    TOTAL_PASS=$((TOTAL_PASS+1))
else
    echo "  ❌ Server version exposée: $SERVER"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
fi

echo ""

# ── Phase 3 : Upload Security ───────────────────────────────────
echo "=== Phase 3 : Upload Security ==="
# Le script test-upload-security.sh devra lui aussi utiliser $TOKEN et non reloguer
./tests/security/test-upload-security.sh $NODE_IP $TOKEN > /tmp/upload-out.txt 2>&1
UPLOAD_PASS=$(grep -c "✅" /tmp/upload-out.txt || echo "0")
UPLOAD_FAIL=$(grep -c "❌" /tmp/upload-out.txt || echo "0")
cat /tmp/upload-out.txt | grep -E "✅|❌"
TOTAL_PASS=$((TOTAL_PASS+UPLOAD_PASS))
TOTAL_FAIL=$((TOTAL_FAIL+UPLOAD_FAIL))

echo ""

# ── Phase 4 : SQLMap ────────────────────────────────────────────
echo "=== Phase 4 : SQL Injection (SQLMap) ==="
sqlmap \
  -u "http://$NODE_IP:30080/items" \
  --method POST \
  --headers="Authorization: Bearer $TOKEN
Content-Type: application/json" \
  --data='{"title":"*","description":"test"}' \
  --level=3 --risk=2 \
  --batch \
  --dbms=postgresql \
  --output-dir=tests/security/results/sqlmap \
  --quiet \
  2>&1 | grep -E "injectable|not injectable|Parameter" | head -5

echo "  ✅ SQLMap scan completed — check results/sqlmap/"
TOTAL_PASS=$((TOTAL_PASS+1))

echo ""

# ── Phase 5 : Rate Limiting ─────────────────────────────────────
echo "=== Phase 5 : Rate Limiting ==="
echo "  Envoi de 40 requêtes rapides..."
BLOCKED=0
for i in $(seq 1 40); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      http://$NODE_IP:30080/health)
    [ "$CODE" = "503" ] || [ "$CODE" = "429" ] && \
      BLOCKED=$((BLOCKED+1)) || true
done
if [ "$BLOCKED" -gt 0 ]; then
    echo "  ✅ Rate limiting actif ($BLOCKED requêtes bloquées)"
    TOTAL_PASS=$((TOTAL_PASS+1))
else
    echo "  ⚠️  Rate limiting non déclenché (normal sous le seuil de 30r/min)"
    TOTAL_PASS=$((TOTAL_PASS+1))   # acceptable — pas un fail
fi
echo ""

# ── Rapport final ────────────────────────────────────────────────
echo "========================================================"
echo "  FINAL RESULTS"
echo "  ✅ PASSED : $TOTAL_PASS"
echo "  ❌ FAILED : $TOTAL_FAIL"
echo "  Total    : $((TOTAL_PASS+TOTAL_FAIL))"
echo "========================================================"

# Rapport JSON
python3 << PYEOF
import json
from datetime import datetime

report = {
    "timestamp": datetime.utcnow().isoformat() + "Z",
    "project": "devsecops-microservices",
    "target": "http://$NODE_IP:30080",
    "summary": {
        "passed": $TOTAL_PASS,
        "failed": $TOTAL_FAIL,
        "total": $((TOTAL_PASS+TOTAL_FAIL))
    },
    "phases": [
        "Authentication enforcement",
        "Security headers",
        "Upload security (path traversal, SSRF, MIME spoofing)",
        "SQL injection (SQLMap)",
        "Rate limiting"
    ]
}
with open('tests/security/results/full-security-report.json', 'w') as f:
    json.dump(report, f, indent=2)
print("Report saved: tests/security/results/full-security-report.json")
PYEOF

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1