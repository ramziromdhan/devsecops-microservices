"""
ZAP hook pour authentification JWT automatique
"""

def zap_started(zap, target):
    # Récupérer un token
    import urllib.request, json, urllib.parse

    data = urllib.parse.urlencode({
        'username': 'ramzi@linsoft.tn',
        'password': 'SecurePass123!'
    }).encode()

    req = urllib.request.Request(
        f'http://{target.split("//")[1].split("/")[0]}/auth/token',
        data=data,
        method='POST'
    )

    try:
        with urllib.request.urlopen(req) as response:
            result = json.loads(response.read())
            token = result.get('access_token', '')

            # Injecter le token dans toutes les requêtes ZAP
            zap.replacer.add_rule(
                description='JWT Auth',
                enabled=True,
                matchtype='REQ_HEADER',
                matchregex=False,
                matchstring='Authorization',
                replacement=f'Bearer {token}'
            )
            print(f"[ZAP Hook] JWT token injected successfully")
    except Exception as e:
        print(f"[ZAP Hook] Auth failed: {e}")
