FROM python:3.9-slim

WORKDIR /app

# Install dependencies
COPY dummy_app.py . 
# Assuming prometheus_client and Flask are the only dependencies for this simple app
# For a real app, you would copy a requirements.txt and run pip install -r requirements.txt
RUN pip install --no-cache-dir Flask prometheus_client

EXPOSE 8008

CMD ["python", "dummy_app.py"] 