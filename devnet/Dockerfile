ARG NODE_VERSION=10.7.0
FROM ghcr.io/intersectmbo/cardano-node:${NODE_VERSION}

COPY genesis/ /genesis/
COPY entrypoint.sh /entrypoint.sh

EXPOSE 3001
VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
