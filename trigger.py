import jwt
import time
import requests

# Your app credentials (get these from app settings)
CLIENT_ID = "Iv23lioPFqXCdJ2hBzVD"
INSTALLATION_ID = "79193558"
PRIVATE_KEY_PATH = "jenkins-e2e-integration.2025-08-04.private-key.pem"

def get_installation_token():
    # Read private key
    with open(PRIVATE_KEY_PATH, 'r') as key_file:
        private_key = key_file.read()

    # Create JWT
    payload = {
        'iat': int(time.time()),
        'exp': int(time.time()) + 600,
        'iss': CLIENT_ID
    }

    jwt_token = jwt.encode(payload, private_key, algorithm='RS256')

    # Get installation access token
    response = requests.post(
        f'https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens',
        headers={
            'Authorization': f'Bearer {jwt_token}',
            'Accept': 'application/vnd.github.v3+json'
        }
    )

    return response.json()['token']

def trigger_github_action():
    token = get_installation_token()
    print(token)

    response = requests.post(
        'https://api.github.com/repos/nathowar-te/eyebrow-linux-build/dispatches',
        headers={
            'Authorization': f'token {token}',
            'Accept': 'application/vnd.github.v3+json'
        },
        json={
            'event_type': 'jenkins_build_complete',
            'client_payload': {
                'build_number': '123',
                'status': 'success',
                'triggered_by': 'github_app'
            }
        }
    )
    
    if response.status_code == 204:
        print("✅ GitHub Action triggered successfully!")
    else:
        print(f"❌ Failed: {response.status_code} - {response.text}")

if __name__ == "__main__":
    trigger_github_action()