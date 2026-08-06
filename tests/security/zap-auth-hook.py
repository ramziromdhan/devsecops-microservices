"""
ZAP hook pour authentification JWT automatique
"""

def zap_started(zap, target):
    import urllib.request, json, urllib.parse, os

    # Récupérer les identifiants depuis les variables d'environnement (passées via Docker)
    test_user = os.environ.get('TEST_USER')
    test_pass = os.environ.get('TEST_PASS')

    if not test_user or not test_pass:
        print("[ZAP Hook] ❌ Erreur : Les variables d'environnement TEST_USER ou TEST_PASS sont introuvables.")
        return

    # Utiliser les identifiants sécurisés pour générer le token
    data = urllib.parse.urlencode({
        'username': test_user,
        'password': test_pass
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
            print(f"[ZAP Hook] ✅ JWT token injected successfully")
    except Exception as e:
        print(f"[ZAP Hook] ❌ Auth failed: {e}")