# Build Docker. ONE image, TWO entrypoints: /bin/walker-waterworld (the game
# server, which also owns the LLM decision layer, because the game pod is the
# only container the platform injects the anthropic_api_key coworld secret into)
# and /bin/walker-waterworld-player (the thin seat registrar). The whole policy
# set is env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED),
# which is what keeps a champion and a scripted filler byte-identical apart from
# their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/waterworld
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# nim.cfg pins the AUTHOR's package paths; rebuild it from this container's tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  cat nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/waterworld-nimcache \
  --out:walker-waterworld \
  src/walker_waterworld.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/waterworld-player-nimcache \
  --out:walker-waterworld-player \
  src/walker_waterworld_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/waterworld
COPY --from=build /workspace/waterworld/walker-waterworld /bin/walker-waterworld
COPY --from=build /workspace/waterworld/walker-waterworld-player \
  /bin/walker-waterworld-player
COPY --from=build /workspace/waterworld/*.json ./
COPY --from=build /workspace/waterworld/data ./data
COPY --from=build /workspace/waterworld/client ./client

CMD ["/bin/walker-waterworld"]
