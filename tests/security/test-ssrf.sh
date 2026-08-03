#!/bin/bash
NODE_IP=$1
TOKEN=$2

echo "=== Tests SSRF sur file-service ==="

# Test 1 — filename avec path traversal
echo "Test 1: Path traversal via filename"
curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/etc/passwd;filename=../../../etc/passwd" \
  | python3 -m json.tool

# Test 2 — fichier avec extension double
echo "Test 2: Double extension"
echo "<?php system('id'); ?>" > /tmp/malicious.php.txt
curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/tmp/malicious.php.txt" \
  | python3 -m json.tool

# Test 3 — fichier trop volumineux
echo "Test 3: Oversized file (11MB)"
dd if=/dev/urandom of=/tmp/large.txt bs=1M count=11 2>/dev/null
curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/tmp/large.txt" \
  | python3 -m json.tool

# Test 4 — null byte injection dans le nom
echo "Test 4: Null byte injection"
curl -s -X POST http://$NODE_IP:30080/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F $'file=@test.txt;filename=shell.php\x00.txt' \
  | python3 -m json.tool

# Test 5 — sans authentification
echo "Test 5: Upload sans auth"
curl -s -X POST http://$NODE_IP:30080/upload \
  -F "file=@test.txt" \
  | python3 -m json.tool

echo "=== Tests terminés ==="
