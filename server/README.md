# NotallyXYZ server

Zero-knowledge sync server for NotallyXYZ (Android fork of NotallyX, macOS, Linux and Windows apps).

- Stores only ciphertext. Notes, labels and attachments are encrypted on the device
  (AES-256-GCM, key from the sync key with HKDF). The server never gets the key.
- No user names, no e-mail, no passwords. An account is the SHA-256 of a token that
  the client derives from its sync key.
- No IP addresses in logs or storage. Access logs are off.
- One static Go binary (7 MB), embedded bbolt database, `scratch` image, runs as
  non-root with a read-only file system and no capabilities.

Protocol and crypto: [PROTOCOL.md](PROTOCOL.md).

## Run with Docker

Copy `compose.yaml`, `Caddyfile` and `.env.example` to the host (or clone the repository), then:

```zsh
cp .env.example .env
# Set SIGNUP_TOKEN to a long random value, for example: openssl rand -base64 32
```

Prebuilt image (built by GitHub Actions for amd64 and arm64 on every `v*` tag):

```zsh
echo 'NOTALLYXYZ_IMAGE=ghcr.io/turtlecute33/notallyxyz-server:1.0' >> .env
docker compose pull server
docker compose up -d --no-build
```

If the image package is private, first run `docker login ghcr.io` with a token that has only
`read:packages`. Or build on the host from the source: `docker compose up -d --build`.

The server listens on `127.0.0.1:8080` of the host. Put it behind HTTPS:

- **Existing reverse proxy** (Caddy, Traefik, nginx, Pangolin/Newt): forward a host name
  to `127.0.0.1:8080` (or to the container `server:8080` on a shared Docker network).
  Do not put an SSO or login page in front of it: the apps cannot use it.
  Allow request bodies up to the attachment limit (100 MB by default) and request
  times of at least 60 s (long poll).
- **Caddy included here**: set `DOMAIN` in `.env`, point DNS to the server, open ports
  80 and 443, then `docker compose --profile caddy up -d --build`.

Check: `curl https://<your host>/v1/health` prints `ok`.

## First setup

1. Set `SIGNUP_TOKEN` and start the server.
2. In NotallyXYZ on Android: Settings → Sync → Create new account. Enter the server URL
   and the token. Save the sync key that the app shows in your password manager.
3. On other devices: Connect with sync key.
4. Optional, recommended: remove `SIGNUP_TOKEN` from `.env` and run
   `docker compose up -d` again. Then nobody can create accounts.

## Configuration

| Variable          | Default  | Meaning                                                   |
|-------------------|----------|-----------------------------------------------------------|
| `SIGNUP_TOKEN`    | empty    | Invite token for new accounts. Empty = signups disabled.  |
| `MAX_BLOB_MB`     | 100      | Largest attachment                                        |
| `MAX_ACCOUNT_MB`  | 0        | Storage quota per account, 0 = none                       |
| `MAX_ACCOUNTS`    | 0        | Number of accounts, 0 = no limit                          |
| `TRUST_PROXY`     | false    | Use `X-Forwarded-For` (last entry) for the rate limit     |
| `LISTEN_ADDR`     | `:8080`  |                                                           |
| `DATA_DIR`        | `/data`  |                                                           |

## Backup

All data is in the `data` volume (`notallyxyz.db` and `blobs/`). It is encrypted by
the clients, so a copy of it is safe to keep anywhere. Stop the container (or copy the
database while no sync runs) for a consistent copy:

```zsh
docker compose stop server
docker run --rm -v notallyxyz-server_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/notallyxyz-data.tgz -C /data .
docker compose start server
```

## What the server can see

Number and size class of records and attachments (sizes are padded), when they change,
and the client IP address of each request (not stored). It cannot read or change note
content: every record is authenticated with its id and kind, so the server also cannot
swap records without detection. Deletions are sealed too: a forged deletion is not applied
on the devices, and they write their copy to the server again. The same applies to anyone
who gets the bearer token, for example a TLS-terminating proxy.

The server can still delete data on the server, withhold updates, or send an older
authentic version of a record again (rollback). Keep a local backup of your notes on one
device (the Android app has automatic backups).

## Development

```zsh
go test -race ./...
go run ./cmd/vectors > testvectors.json   # only if the crypto changes
DATA_DIR=/tmp/nxyz SIGNUP_TOKEN=dev-invite-0123456789 LISTEN_ADDR=127.0.0.1:8080 go run .
```

## License

GPL-3.0, same as NotallyX.
