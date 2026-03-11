# Overridden by create.ps1 via --build-arg DAB_VERSION=...
ARG DAB_VERSION=INVALID-SET-BY-CREATE
FROM mcr.microsoft.com/azure-databases/data-api-builder:${DAB_VERSION}

# redeclare ARG so it's in scope again after FROM
ARG DAB_VERSION

LABEL org.opencontainers.image.title="dab-configured" \
      org.opencontainers.image.description="Data API Builder with baked configuration for Azure deployment" \
      org.opencontainers.image.version="${DAB_VERSION}" \
      org.opencontainers.image.authors="data-api-builder@microsoft.com"

# Copy configuration (DAB looks for /App/dab-config.json by default)
COPY dab-config.json /App/dab-config.json
RUN chmod 444 /App/dab-config.json || true

# Note: Container Apps provides its own health probes at the platform level.
# The /health endpoint requires runtime.health configuration in dab-config.json.
# For simplicity, we rely on Container Apps TCP port checks rather than HTTP health checks.
# If you need HTTP health checks, add runtime.health config to dab-config.json as per:
# https://github.com/Azure/data-api-builder/blob/main/docs/design/HealthEndpoint.md

# Document default port (Container Apps may infer but this aids local runs)
EXPOSE 5000

# Connection string supplied at runtime via environment variable.
