# Regional router image. Base image pinned by tag and digest.
ARG PYTHON_IMAGE=python:3.13.18-slim-trixie@sha256:ae14d4ce8771606477a81446e7ef429edd6762305fc50c84507c1041fa8285d1

FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /src
COPY pyproject.toml ./
COPY app ./app
RUN pip install --prefix=/install .

FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin router
COPY --from=build /install /usr/local
USER 10001
EXPOSE 8080
# Keep-alive longer than the ALB idle timeout (3600 s) so the ALB, not the
# router, closes idle connections.
ENTRYPOINT ["uvicorn", "--factory", "app.main:app_factory", \
            "--host", "0.0.0.0", "--port", "8080", \
            "--timeout-keep-alive", "3700", "--no-server-header"]
