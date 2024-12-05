# Gitea setup with Docker

#### Gitea space
```sh
sudo mkdir /gitea
sudo chown $USER:$USER /gitea
cd /gitea && mkdir mysql
```

#### Build docker containers
```sh
# -d to run in detached mode
sudo docker compose up -d
```

#### Configure SHH
```sh
# create ~/.ssh/config and paste:
Host gitea
  HostName hostname -I | awk '{print $1}'
  User git
  IdentityFile ~/.ssh/key
  Port 222
  IdentitiesOnly yes
```

## LICENSE
Unlicense. You can do whatever you want with the repo files.
