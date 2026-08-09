#!/bin/bash
source monitoring/defectdojo/.dd-config

echo "=== Export Trivy Operator → DefectDojo ==="

mkdir -p /tmp/trivy-operator-reports

# Récupérer tous les VulnerabilityReports
kubectl get vulnerabilityreports -n devsecops-prod \
  -o json > /tmp/trivy-operator-reports/all-reports.json

# Convertir en format Trivy JSON compatible DefectDojo
python3 << 'PYEOF'
import json

with open('/tmp/trivy-operator-reports/all-reports.json') as f:
    data = json.load(f)

for item in data['items']:
    container = item['metadata']['labels'].get(
        'trivy-operator.container.name', 'unknown')
    report = item.get('report', {})
    vulns = report.get('vulnerabilities', [])

    # Construire un rapport Trivy-compatible
    trivy_report = {
        "Results": [{
            "Target": container,
            "Type": "container_image",
            "Vulnerabilities": [{
                "VulnerabilityID": v.get('vulnerabilityID'),
                "PkgName": v.get('resource'),
                "InstalledVersion": v.get('installedVersion'),
                "FixedVersion": v.get('fixedVersion',''),
                "Severity": v.get('severity'),
                "Title": v.get('title',''),
                "Description": v.get('description','')
            } for v in vulns]
        }]
    }

    outfile = f'/tmp/trivy-operator-reports/{container}.json'
    with open(outfile, 'w') as f:
        json.dump(trivy_report, f, indent=2)
    print(f"  Generated: {outfile} ({len(vulns)} vulns)")
PYEOF

# Importer chaque rapport dans DefectDojo
for report_file in /tmp/trivy-operator-reports/*.json; do
    [ "$report_file" = "/tmp/trivy-operator-reports/all-reports.json" ] && continue

    container=$(basename $report_file .json)
    echo "Importing $container..."

    curl -s -X POST "$DD_URL/api/v2/import-scan/" \
        -H "Authorization: Token $DD_TOKEN" \
        -F "scan_type=Trivy Scan" \
        -F "file=@$report_file" \
        -F "product_name=$PRODUCT_NAME" \
        -F "engagement_name=CI/CD Scans" \
        -F "auto_create_context=true" \
        -F "active=true" \
        -F "close_old_findings=false" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  ✅ OK' if 'test' in d else f'  ❌ {str(d)[:100]}')
" 2>/dev/null
done

echo "=== Export terminé ==="
