FROM searxng/searxng:latest@sha256:60055af6f2f1ca14b488d9c0f47a019d1dbaf15b4f6547a7194253bf2ab94744

# Copy configuration files directly into the image
COPY searxng/settings.yml /etc/searxng/settings.yml
COPY searxng/limiter.toml /etc/searxng/limiter.toml

# Ensure correct permissions
USER root
RUN chmod 644 /etc/searxng/settings.yml /etc/searxng/limiter.toml && \
    chown searxng:searxng /etc/searxng/settings.yml /etc/searxng/limiter.toml && \
    chown -R searxng:searxng /etc/ssl/certs

USER searxng
