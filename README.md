# Gitea (Docker) — production self-hosting via Cloudflare Tunnel

A locked-down Gitea deployment for hosting **your own** code: you are the only
admin, self-registration is disabled, and visitors can view your public repos
read-only. Served over HTTPS through a Cloudflare Tunnel; SSH stays on your LAN.

**Access model**
- **Web / API / git-over-HTTPS** — one port (`8989`), published to `127.0.0.1`
  and exposed publicly by your Cloudflare Tunnel. This is the *only* thing the
  tunnel maps. The database is never exposed.
- **Push from anywhere** — over HTTPS with a Gitea personal access token:
  `https://git.example.com/you/repo.git`
- **Push from home** — over SSH, LAN-only (never goes through the tunnel):
  `git@<server-lan-ip>:222/you/repo.git`

**Security posture (baked into `docker-compose.yml`)**
- `DISABLE_REGISTRATION=true` — nobody can self-register.
- `INSTALL_LOCK=true` — the web install wizard is disabled; you create the admin
  from the CLI (below).
- `DEFAULT_PRIVATE=private` — new repos are private until you publish them.
- OpenID sign-in/up and org creation disabled.
- `REQUIRE_SIGNIN_VIEW` — defaults to `false` so the public can view public
  repos read-only. Set `true` in `.env` to force login even to view.

---

## 1. Prepare the data directory
```sh
sudo mkdir -p /gitea /gitea/mysql
sudo chown -R 1000:1000 /gitea      # matches USER_UID/USER_GID in the container
```

## 2. Generate configuration and secrets
`setup.sh` asks a few questions and writes `.env` with all secrets generated
(DB passwords, `SECRET_KEY`, `INTERNAL_TOKEN`). It auto-detects your LAN IP for
the SSH clone URL.
```sh
./setup.sh
```
> `.env` holds secrets and is gitignored — never commit it. To reconfigure,
> re-run `setup.sh` (it backs up the old `.env` first).

## 3. Start the stack
```sh
sudo docker compose up -d          # add -d to run detached
```

## 4. Create your admin account
Registration is disabled and the install wizard is locked, so make your admin
from the CLI (change the values). Notes:
- `server` is the **compose service name** — `docker compose exec` wants the
  service, not the container name.
- `-u git` is required: Gitea refuses to run as root, and `exec` defaults to root.
```sh
docker compose exec -u git server gitea admin user create \
  --admin --username YOURNAME --email you@example.com \
  --password 'PICK-A-PASSWORD' --must-change-password=false
```
You can change this password anytime, later, on the server.

## 5. Point the Cloudflare Tunnel at the frontend port
Map your tunnel hostname to the local web port — **only** this port:
```yaml
# ~/.cloudflared/config.yml (running cloudflared on the server host)
ingress:
  - hostname: git.example.com
    service: http://localhost:8989
  - service: http_status:404
```
Cloudflare terminates TLS at the edge; the origin stays plain HTTP on
`127.0.0.1:8989`. No firewall ports need to be opened for the web side.

> Keep the DNS record for `git.example.com` **proxied** (orange cloud).
> Note: Cloudflare limits a single request body to ~100 MB — very large HTTPS
> pushes can fail; use Git LFS or push those over SSH on your LAN.

---

## SSH access (LAN, for your own pushes)
SSH is reachable on your local network only (the tunnel carries HTTP, not SSH).
Add an alias so you don't retype the IP/port — use your server's LAN IP:
```sh
# ~/.ssh/config
Host gitea
  HostName 192.168.1.50      # your server's LAN IP (GITEA_SSH_DOMAIN)
  User git
  IdentityFile ~/.ssh/key
  Port 222                   # GITEA_SSH_PORT
  IdentitiesOnly yes
```
Then: `git clone gitea:you/repo.git`. Upload your **public** key under
Gitea → Settings → SSH Keys first.

> Pin the server's LAN IP with a DHCP reservation (or static IP) so it doesn't
> drift. If it changes, update `GITEA_SSH_DOMAIN` in `.env` and run
> `docker compose up -d`.
>
> This assumes the server sits behind your home router (NAT), which keeps port
> `222` LAN-only automatically. On a public-IP VPS, add a firewall rule
> allowing `222` from your LAN subnet only.

## Actions Runner

The runner lets you run Gitea Actions workflows on this server — e.g.
auto-deploying a project when you push to a branch. It's optional.

#### Get the registration token
1. Go to your Gitea instance → **Admin Panel** → `/admin/runners`
2. Click **Create Runner** and copy the token
3. Put it in `.env` as `RUNNER_TOKEN` (or answer the runner prompts in `setup.sh`)

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

#### Start / verify the runner
The runner starts with `docker compose up -d` and registers itself on first
boot. Check **Admin Panel** → `/admin/runners` — it should appear online.

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
- The repo's normal SSH remote won't resolve inside the job, so pull over HTTP
  using the server IP and the auto-injected `secrets.GITEA_TOKEN`.

> The runner mounts the host Docker socket (root-equivalent). Since only you can
> push code and define workflows, the risk is contained — but don't grant others
> write access. If you don't need CI, skip the runner entirely.

## Backups
Back up regularly: the `/gitea` volume (repos, config, attachments) and the
MySQL data. The simplest all-in-one is `docker compose exec -u git server gitea dump`,
shipped off the server.

## LICENSE
Unlicense. You can do whatever you want with the repo files.
