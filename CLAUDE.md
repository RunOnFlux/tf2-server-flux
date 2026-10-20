# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**: the Team Fortress 2 dedicated server for Flux,
`runonflux/tf2-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's 64-bit Linux srcds, and a
supervisor in bash. Started from `~/work/garrysmod-server-flux`; the srcds patterns (pty, FIFO,
exit file, `script` killed once srcds is gone) are that repo's and its CLAUDE.md explains them.

## Commands

```bash
./tests/test-flux.sh
docker build -t tf2-server-flux:local .
./tests/test-image.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

## Things that will bite you

- **64-bit**: `srcds_run_64` / `srcds_linux64`, and `libcurl3t64-gnutls` or replay_srv.so fails.
- **tf/ is most of the ~15 GB install**: only custom/, addons/, cfg/sourcemod and the ban lists are on the data
  volume, as links. Never make the whole tf/ synced.
- **SourceMod is unpacked aside and copied**: tar cannot write through the links.
- **One Metamod loader**: `metamod_x64.vdf`. The archive's `metamod.vdf` is removed: two loaders
  load Metamod twice and SourceMod fails to attach.
- **Metamod stable (1.12), not 2.0 dev**, with SourceMod 1.12.
- Everything in garrysmod-server-flux's CLAUDE.md about srcds, `script` and the console applies.
- **Admins are merged, never rewritten** (`set-admins`): a line the panel cannot represent (a
  group, an IP or name admin, a password, a comment) is written back exactly as it was.
- **srcds loads plain .bsp only**: a .bsp.bz2 upload is unpacked; .bz2 is for FastDL.
- **Backups and restores are fluxtf2.py's** (`backup`, `apply-restore`); the supervisor only calls
  them. A restore is applied between two servers, via the restart marker and `quit`.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume: a constantly written file there is constant Syncthing traffic. `flux_log_migrate` moves an old one off the data volume at start. `flux_banner` prints the FluxCloud banner at container start and every generation; its text is tested.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`): urgent security updates, or commits on main since the published `:latest` (label `org.opencontainers.image.revision`) that touch the image inputs.
