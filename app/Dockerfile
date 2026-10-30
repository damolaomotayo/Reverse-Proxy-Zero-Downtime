ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv
COPY app.py .
RUN useradd --system --no-create-home appuser
USER appuser
EXPOSE 8080
CMD ["python", "app.py"]
