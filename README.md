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

#### Configure allowed mounts
Jobs run inside throwaway containers, so a workflow can only reach host
directories it explicitly bind-mounts — and the runner only permits paths
listed in `config.yaml`:
```sh
cp config.yaml.example config.yaml
# edit container.valid_volumes to include the directory where your repos live
```
Without this, the runner silently drops the mount and your workflow fails with
`is not a valid volume, will be ignored` (and later `No such file or directory`).

#### Start the runner
The runner starts automatically with `docker compose up -d`. It registers itself with Gitea on first boot.

#### Verify the runner is connected
Go to **Admin Panel** → `/admin/runners` — the runner should appear as online.

#### Example workflow
Create `.gitea/workflows/deploy.yml` in your repository:

```yaml
on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest
    container:
      # Mount the host directory holding your repo into the job container.
      # This path must be allowed by container.valid_volumes in config.yaml.
      options: -v /home/user:/home/user
    steps:
      - name: Pull and deploy
        run: |
          cd /home/user/your-repo
          # Pull over HTTP using the runner-reachable Gitea URL + the built-in
          # Actions token (no SSH host alias, which won't resolve in the container).
          git pull http://x-access-token:${{ secrets.GITEA_TOKEN }}@<GITEA_IP>:<PORT>/owner/your-repo.git main
          docker compose up -d --build
```

How the access works:
- The job runs in a container, so it cannot see host paths unless mounted —
  hence the `container.options` bind, gated by `valid_volumes`.
- The Docker socket is auto-mounted into the job, so `docker compose` here drives
  the **host** Docker daemon (build context and volumes resolve to host paths).
- The repo's normal SSH remote (`git@gitea:...`) won't resolve inside the job, so
  pull over HTTP using the server IP and the auto-injected `secrets.GITEA_TOKEN`.

## LICENSE
Unlicense. You can do whatever you want with the repo files.
