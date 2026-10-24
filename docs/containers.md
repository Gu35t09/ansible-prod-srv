# Working with containers

How to look at and operate the containers on the server with `docker-svc`. For what the roles set up, see [walkthrough.md](walkthrough.md); for routine maintenance, [maintenance.md](maintenance.md).

Contents:

1. [How it fits together](#1-how-it-fits-together)
2. [Everyday commands](#2-everyday-commands)
3. [Changes go through Ansible](#3-changes-go-through-ansible)
4. [Networks](#4-networks)
5. [Logs](#5-logs)
6. [Disk space](#6-disk-space)
7. [When something is wrong](#7-when-something-is-wrong)
8. [What not to do](#8-what-not-to-do)

---

## 1. How it fits together

- Docker runs **rootless**, as the service user `svc-docker`, which has no login and no sudo. Root inside a container is `svc-docker` on the host, not root.
- The admin user has **no access to the Docker socket**. `docker-svc` (`/usr/local/bin/docker-svc`) runs the `docker` CLI as `svc-docker` through sudo. It takes exactly the same arguments as `docker`, and every use is recorded in the journal (`journalctl _COMM=sudo`).
- Every service has its own directory, owned by root with group `svc-docker`: readable by the service user, not by the admin without sudo.

  ```text
  /srv/docker/
  ├── system/<name>/   # infrastructure: traefik, technitium, renovate
  └── app/<name>/      # applications: vaultwarden, immich, opencloud, paperless
      ├── compose.yml  # written by Ansible
      ├── data/        # the service's data (bind mounts)
      └── dump/        # database dumps, for the backup (if it has a database)
  ```

## 2. Everyday commands

**What is running**

```bash
docker-svc ps                      # running containers, with status and health
docker-svc ps -a                   # stopped ones too
docker-svc stats --no-stream       # CPU and memory per container
```

**One service**: always pass its compose file with `-f`. The admin cannot enter the directory, but `docker-svc` can.

```bash
docker-svc compose -f /srv/docker/system/traefik/compose.yml ps
docker-svc compose -f /srv/docker/system/traefik/compose.yml restart
docker-svc compose -f /srv/docker/system/traefik/compose.yml stop
docker-svc compose -f /srv/docker/system/traefik/compose.yml up -d     # start again after a stop
```

For an application the path is `/srv/docker/app/<name>/compose.yml`.

**Inside a container**

```bash
docker-svc logs --tail 50 <container>
docker-svc exec -it <container> sh          # most images have sh, not bash
docker-svc inspect <container>
docker-svc inspect <container> --format '{{.State.Health.Status}}'
```

**Files of a service**: with sudo, because the directories are closed to the admin.

```bash
sudo ls -la /srv/docker/app/<name>/
sudo less /srv/docker/app/<name>/compose.yml
```

## 3. Changes go through Ansible

The repository is the source of truth. A compose file or a configuration file changed by hand on the server is overwritten at the next run.

| To | Do |
| --- | --- |
| Change a setting | Edit the role or `group_vars` in the repository, then `ansible-playbook site.yml --tags <service> --ask-vault-pass` |
| Update an image | Change the pinned version (tag and digest) in the role's defaults (later: merge the Renovate PR), then `--tags update-containers` |
| Add a service | Add its name to `traefik_networks` in `main.yml` and run `--tags traefik` (it creates the service's network), then deploy the service role. See the walkthrough, "Adding a service" |
| Remove a service | Remove its role from `site.yml` and its name from `traefik_networks`, stop it (`docker-svc compose -f ... down`), run `--tags traefik`, then remove its network (`docker-svc network rm proxy-<name>`) and, once you are sure, its directory |

Restarting, stopping and looking at containers by hand is fine: it changes nothing that Ansible manages.

## 4. Networks

Every service behind Traefik has its own **internal** network, `proxy-<name>`, which only Traefik and that service join:

- services cannot reach each other through these networks; they do not even resolve each other's names;
- an internal network has no route to the Internet. A service that needs outbound access (for example Immich downloading its models) gets it on its own default network, never through Traefik's;
- Traefik is on all of them, plus its own `default` network to reach Let's Encrypt and Cloudflare.

```bash
docker-svc network ls
docker-svc network inspect proxy-<name> --format '{{range .Containers}}{{.Name}} {{end}}'   # traefik and the service, nothing else
```

The networks are created by the Traefik role from `traefik_networks`, not by compose: they exist before either container starts and survive either being recreated.

## 5. Logs

| Service | Where |
| --- | --- |
| Traefik | `sudo tail -f /srv/docker/system/traefik/logs/access.log` (requests) and `traefik.log` (errors, certificates); rotated daily, 30 days |
| Other containers | `docker-svc logs <container>`; at most 3 files of 10 MB per container, **lost when the container is recreated** (at every update) |
| Rootless Docker daemon | `sudo journalctl _SYSTEMD_USER_UNIT=docker.service _UID=$(id -u svc-docker)` |

A service whose logs matter after an update (security events, errors to investigate) should write them to files under its directory, like Traefik.

## 6. Disk space

```bash
docker-svc system df               # images, containers, volumes
docker-svc image prune -a          # remove images no container uses (monthly, see the maintenance guide)
```

Never delete files under `~svc-docker/.local/share/docker` by hand: always use `docker-svc`.

## 7. When something is wrong

| Symptom | Look at |
| --- | --- |
| A container is `unhealthy` or keeps restarting | `docker-svc ps -a`, `docker-svc logs --tail 100 <container>`, then the service's own log files |
| A service is not reachable through Traefik | Its route in the Traefik dashboard (`https://proxy.greyroom.net`), `traefik.log`, and whether both containers are on `proxy-<name>` (section 4) |
| `docker-svc` says it cannot connect to the daemon | The rootless daemon: see the maintenance guide, "Rootless Docker does not start" |
| Containers did not come back after a reboot | `sudo loginctl show-user svc-docker -p Linger` (must be `Linger=yes`), then the daemon journal above |

## 8. What not to do

- **Do not add the admin user to the `svc-docker` group** to skip sudo: the group also opens the Docker socket, which means control of every container.
- **Do not edit files under `/srv/docker` on the server**: change the repository and run the playbook.
- **Do not `pull` and `up` by hand to update**: the pinned version in the repository is what runs; use `--tags update-containers`.
- **Do not start containers with `docker-svc run`** for anything that should stay: it is invisible to the repository and to the backup. Quick tests are fine if you remove them (`--rm`).
- **Do not publish a service's ports** in its compose file: every service is reached through Traefik.
