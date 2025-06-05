FROM python:3.9-slim

WORKDIR /app

# Install dependencies, including curl for the healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

COPY dummy_app.py . 
# Assuming prometheus_client and Flask are the only dependencies for this simple app
# For a real app, you would copy a requirements.txt and run pip install -r requirements.txt
RUN pip install --no-cache-dir Flask prometheus_client

EXPOSE 8008

CMD ["python", "dummy_app.py"] 