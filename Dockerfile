FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY exporter.py .

# Non-root user
RUN groupadd -r exporter && useradd -r -g exporter exporter
USER exporter

EXPOSE 9110

ENTRYPOINT ["python", "exporter.py"]
