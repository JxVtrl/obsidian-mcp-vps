# Troubleshooting

Everything here happened on a real box (Hostinger KVM 2, Ubuntu 24.04).

## Every call takes 30-40 seconds

**Symptom.** Each tool call from the client takes half a minute. `ps` shows
dozens of `npx` / `node` processes. Swap is 100% full.

**Cause.** The first version of this setup put
[supergateway](https://github.com/supercorp-ai/supergateway) between the tunnel
and the filesystem server to turn stdio into streamable HTTP. In its default
stateless mode it starts a **new** stdio server process per request and those
children were never reaped. Combine that with `npx -y` in the unit's
`ExecStart` (a package resolution on every spawn) and each call is a cold
start on a machine that is already swapping.

**What didn't work.** `--stateful` on supergateway: with an auth proxy in front
that doesn't forward `mcp-session-id`, every call errors.

**Fix.** Remove the layer. `mcp-auth-proxy` already converts stdio to `/mcp`
and manages one long-lived child process itself. That is what
`docker-compose.yml` in this repo does. The mounted npm cache volume keeps
`npx` from re-downloading on container recreate.

If you must keep a stdio gateway: install the packages globally and call the
binaries directly, never `npx -y` at runtime.

## The client connects but every request fails

Check the transport. Claude's custom connectors expect **streamable HTTP**.
A server exposed as SSE answers `curl` fine and still fails in the client.
With this repo the endpoint is always `https://<host>/mcp`.

## Tunnel drops with QUIC errors

**Symptom.** `cloudflared` logs fill with QUIC timeouts, the hostname flaps
between 200 and 530.

**Fix.** Force HTTP/2.

- Locally managed tunnel: `protocol: http2` in `/etc/cloudflared/config.yml`.
- Token tunnel (dashboard managed): add `--protocol http2` to the
  `cloudflared tunnel run` command in the systemd unit.

Also worth knowing: with a token tunnel the ingress rules live in the
dashboard. Editing `config.yml` on the server changes nothing.

## Sync stopped and nobody noticed

Three separate bugs, all fixed in `scripts/vault-sync.sh`:

1. **Pull before commit.** If anything wrote a note between runs,
   `git pull --rebase` refuses on the dirty tree. Commit first.
2. **Overlapping runs.** A slow pull plus a 2-minute cron means two git
   processes in one repo. `flock -n` makes the second one skip.
3. **Stuck rebase.** After one conflict the repo sits mid-rebase and every
   later run fails quietly. The script now detects it and exits 1 with a
   message in `/var/log/vault-sync.log`.

To recover from a stuck rebase:

```sh
cd /opt/vault
git status            # see what conflicted
git rebase --abort    # or resolve, then: git rebase --continue
```

## Push fails after the first sync

Branch name mismatch (`master` locally, `main` on the remote). Set
`VAULT_BRANCH` in the cron line or rename the branch.

## vault-writer returns 401 with a token that looks right

The token was probably truncated when copied from a terminal or a screenshot.
Compare lengths: `cut -d= -f2 /etc/vault-writer.env | wc -c` should print 65.

## vault-writer returns 405

It only speaks `GET`, `HEAD` and `PUT`. Tools that default to `POST` need the
method changed.

## Services reachable without the tunnel

`ss -tlnp` should show `127.0.0.1` in front of 8082 and 8083. If you see
`0.0.0.0` or `*`, something is published on the public interface: fix the
bind address first, then make sure `ufw` only allows SSH.
