# Team Fortress 2 dedicated server image for Flux.
#
# Written from scratch. The game's native 64-bit Linux server (Steam app 232250, srcds), installed and
# updated with SteamCMD on every start, under a supervisor that builds the launch line from the
# environment, runs srcds in a pseudo-terminal so its console reaches the logs (srcds writes
# nothing once the map is up without one), rotates those logs, quits cleanly on stop and restarts
# the server in place. See README.md.
FROM steamcmd/steamcmd:ubuntu-24

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# TF2's server is 64-bit since 2024. libcurl3t64-gnutls: replay_srv.so needs libcurl-gnutls.so.4,
# and srcds dies with "Could not load: replay_srv.so" without it (measured). `script` (util-linux)
# gives srcds its terminal.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 util-linux libcurl3t64-gnutls && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/flux-launch.py scripts/fluxtf2.py server.cfg /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console && \
    ln -s /opt/flux/fluxtf2.py /usr/local/bin/flux-tf2

RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/tf2/server", "/mnt/tf2/data"]

# One port: the game and the Steam query over UDP, RCON over TCP.
EXPOSE 27015/udp 27015/tcp

HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -f srcds_linux64 >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
