#!/bin/bash
set -e

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
echo "Target: http://$NODE_IP:30080"

# Login
TOKEN=$(curl -s -X POST http://$NODE_IP:30080/auth/token \
  -d "username=ramzi@linsoft.tn&password=SecurePass123!" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "Token obtenu: ${TOKEN:0:20}..."

mkdir -p tests/security/results

# ── 1. Test d'authentification ────────────────────────────────
echo ""
echo "=== 1. Tests d'authentification ==="

# Mauvais password
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://$NODE_IP:30080/auth/token \
  -d "username=ramzi@linsoft.tn&password=wrongpass")
[ "$RESULT" = "401" ] && echo "✅ Wrong password → 401" || echo "❌ Wrong password → $RESULT"

# Token invalide
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  http://$NODE_IP:30080/items \
  -H "Authorization: Bearer invalid.token.here")
[ "$RESULT" = "401" ] && echo "✅ Invalid token → 401" || echo "❌ Invalid token → $RESULT"

# Sans token
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  http://$NODE_IP:30080/items)
[ "$RESULT" = "401" ] && echo "✅ No token → 401" || echo "❌ No token → $RESULT"

# ── 2. Security headers ──────────────────────────────────────
echo ""
echo "=== 2. Security headers ==="
HEADERS=$(curl -sI http://$NODE_IP:30080/health)

echo "$HEADERS" | grep -qi "X-Frame-Options" \
  && echo "✅ X-Frame-Options présent" || echo "❌ X-Frame-Options manquant"
echo "$HEADERS" | grep -qi "X-Content-Type-Options" \
  && echo "✅ X-Content-Type-Options présent" || echo "❌ X-Content-Type-Options manquant"
echo "$HEADERS" | grep -qi "X-XSS-Protection" \
  && echo "✅ X-XSS-Protection présent" || echo "❌ X-XSS-Protection manquant"

# ── 3. Upload security ───────────────────────────────────────
echo ""
echo "=== 3. Upload security ==="

# Extension interdite
RESULT=$(curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@../../../etc/passwd;filename=test.php" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('BLOCKED' if 'not allowed' in d.get('detail','') else 'PASSED')" 2>/dev/null)
[ "$RESULT" = "BLOCKED" ] && echo "✅ .php bloqué" || echo "❌ .php non bloqué: $RESULT"

# Fichier valide
echo "security test" > /tmp/test-upload.txt
RESULT=$(curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/tmp/test-upload.txt" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'filename' in d else 'FAIL')" 2>/dev/null)
[ "$RESULT" = "OK" ] && echo "✅ Upload .txt autorisé" || echo "❌ Upload .txt échoué"

# ── 4. Rate limiting ─────────────────────────────────────────
echo ""
echo "=== 4. Rate limiting ==="
echo "Envoi de 40 requêtes rapides..."
BLOCKED=0
for i in $(seq 1 40); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$NODE_IP:30080/health)
  [ "$CODE" = "503" ] || [ "$CODE" = "429" ] && BLOCKED=$((BLOCKED+1))
done
[ "$BLOCKED" -gt 0 ] \
  && echo "✅ Rate limiting actif ($BLOCKED requêtes bloquées)" \
  || echo "⚠️  Rate limiting non déclenché (normal sous le seuil)"

# ── Résumé ───────────────────────────────────────────────────
echo ""
echo "=== Résumé des tests de sécurité ==="
echo "Tests exécutés contre: http://$NODE_IP:30080"
echo "Timestamp: $(date)"
