# Gitea setup with Docker
This documentation contains instructions on how to setup Gitea with Docker on locahost machine mainly for using it over the local network.

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

#### Configure SHH
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

## LICENSE
Unlicense. You can do whatever you want with the repo files.
