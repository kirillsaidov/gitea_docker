# Gitea setup with Docker
This documentation contains instructions on how to setup Gitea with Docker on localhost machine mainly for using it over the local network.

#### Gitea space
```sh
sudo mkdir /gitea
sudo chown $USER:$USER /gitea
cd /gitea && mkdir mysql
```

#### Build docker containers
```sh
# '-d' to run in detached mode
sudo docker compose up -d
```

#### Configure SSH
```sh
# create ~/.ssh/config and paste:
Host gitea
  HostName localhost
  User git
  IdentityFile ~/.ssh/key
  Port 222
  IdentitiesOnly yes
```

#### Configure `app.ini` for changing IPs
By default gitea will assign your local machine ip address. However, that address may change over time. Edit the following fields in your `/gitea/gitea/conf/app.ini`:
```sh
[server]
DOMAIN = 0.0.0.0
SSH_DOMAIN = 0.0.0.0
ROOT_URL = http://0.0.0.0:3000/
```

#### Configure `app.ini` for allowed domains
By default gitea will block addresses over local network. Update your `/gitea/gitea/conf/app.ini` to allow local network or block certain domains:
```sh
[migrations]
ALLOWED_DOMAINS = *
ALLOW_LOCALNETWORKS = true
BLOCKED_DOMAINS =
```

## Actions Runner

The runner allows you to run Gitea Actions workflows automatically on this server — for example, auto-deploying a project when you push to a branch.

#### Get the registration token
1. Go to your Gitea instance → **Admin Panel** → `/admin/runners`
2. Click **Create Runner** and copy the token
3. Paste it into `.env` as `RUNNER_TOKEN`

#### Start the runner
The runner starts automatically with `docker compose up -d`. It registers itself with Gitea on first boot.

#### Verify the runner is connected
Go to **Admin Panel** → `/admin/runners` — the runner should appear as online.

#### Example workflow
Create `.gitea/workflows/deploy.yml` in your repository:

```yaml
name: Deploy

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Pull and deploy
        run: |
          cd /home/administrator/FILES/your-repo
          git pull origin main
          docker compose -f docker-compose-server.yml up -d --build --no-deps backend frontend
```

Since the runner mounts the host filesystem via `RUNNER_HOST_MOUNT`, it has direct access to your server directories and Docker without any SSH required.

## LICENSE
Unlicense. You can do whatever you want with the repo files.
