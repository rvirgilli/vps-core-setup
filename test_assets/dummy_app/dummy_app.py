from flask import Flask, Response
from prometheus_client import Counter, Gauge, generate_latest, REGISTRY
import random
import time

app = Flask(__name__)

# Define some dummy metrics
DUMMY_REQUESTS_TOTAL = Counter(
    'dummy_app_requests_total',
    'Total HTTP requests to the dummy app',
    ['endpoint']
)
DUMMY_STATIC_VALUE = Gauge(
    'dummy_app_static_value',
    'A dummy metric with a static value'
)
DUMMY_RANDOM_VALUE = Gauge(
    'dummy_app_random_value',
    'A dummy metric with a random value'
)

# Set a static value for one of the metrics
DUMMY_STATIC_VALUE.set(42)

@app.route('/')
def hello():
    DUMMY_REQUESTS_TOTAL.labels(endpoint='/').inc()
    DUMMY_RANDOM_VALUE.set(random.randint(0, 100))
    return "Hello from Dummy App! Metrics are at /metrics\n"

@app.route('/test')
def test_endpoint():
    DUMMY_REQUESTS_TOTAL.labels(endpoint='/test').inc()
    DUMMY_RANDOM_VALUE.set(random.randint(100, 200))
    return "This is the /test endpoint of Dummy App!\n"

@app.route('/metrics')
def metrics():
    # Update one metric right before scrape for dynamism, if desired
    # DUMMY_RANDOM_VALUE.set(random.randint(0,100))
    return Response(generate_latest(REGISTRY), mimetype='text/plain; version=0.0.4; charset=utf-8')

if __name__ == '__main__':
    # For testing, it's good to unregister default Python metrics if you don't need them,
    # to keep the /metrics output cleaner. This is optional.
    # from prometheus_client import gc_collector, platform_collector, process_collector
    # REGISTRY.unregister(gc_collector.GC_COLLECTOR)
    # REGISTRY.unregister(platform_collector.PLATFORM_COLLECTOR)
    # REGISTRY.unregister(process_collector.PROCESS_COLLECTOR)

    app.run(host='0.0.0.0', port=8008) 