FROM python:3.9-alpine3.13
LABEL maintainer="rhishikesh-chikhalkar"

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY pyproject.toml /tmp/
COPY . /app

EXPOSE 8000

ARG DEV=false
RUN uv venv /py && \
    if [ "$DEV" = "true" ]; then \
        uv pip install --python /py "/tmp[dev]"; \
    else \
        uv pip install --python /py /tmp; \
    fi && \
    rm -rf /tmp && \
    adduser \
    --disabled-password \
    --no-create-home \
    django-user

ENV PATH="/py/bin:$PATH"

USER django-user