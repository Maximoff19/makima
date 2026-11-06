# Derived from the upstream OpenCode image to add Node and the Vercel CLI.
#
# The upstream image is Alpine and ships no node, npm, npx, git or python. That makes two
# published capabilities impossible out of the box: `npx vercel` for deploying to Vercel, and
# any framework build step, since there is no runtime to run it. This layer adds just enough.
#
# Its own directory is the build context on purpose: using the repo root would send config/ --
# which holds makima_token, opencode_password and vercel_token -- into the build context.
FROM ghcr.io/anomalyco/opencode:1.18.33

USER root
RUN apk add --no-cache nodejs npm \
    && npm install -g vercel \
    && npm cache clean --force

# Vercel stores per-project link state under HOME. The compose file already points HOME at a
# writable path inside the workspace, which is the only reason a `vercel link` can persist.
USER 10001
