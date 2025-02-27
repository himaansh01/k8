#!/bin/bash
# ===================================================================================================
# SIMPLIFIED KUBERNETES DEMO SCRIPT
# ===================================================================================================
# This script creates and deploys a minimal Kubernetes application with detailed explanations
# Assumes you already have: Docker, kubectl, and Minikube installed
# ===================================================================================================

# Create project directory
mkdir -p ~/mini-k8s-demo/{app,k8s}
cd ~/mini-k8s-demo

# ===== STEP 1: Create a simple Python Flask application =====
cat > app/app.py << 'EOL'
# Simple Flask application for Kubernetes demonstration
from flask import Flask, jsonify
import os
import socket
import datetime

# Initialize Flask application
app = Flask(__name__)

# Read configuration from environment variables (will be set via Kubernetes ConfigMap)
APP_NAME = os.environ.get('APP_NAME', 'mini-k8s-demo')
APP_VERSION = os.environ.get('APP_VERSION', '1.0.0')

# Track request count to demonstrate statelessness in Kubernetes
request_count = 0

@app.route('/')
def index():
    """Main page showing container/pod information"""
    global request_count
    request_count += 1
    
    # Return HTML with pod information - demonstrates how each pod is a separate instance
    return f"""
    <h1>Kubernetes Mini Demo</h1>
    <p>App: {APP_NAME} v{APP_VERSION}</p>
    <p>Hostname (Pod name): {socket.gethostname()}</p>
    <p>Pod IP: {socket.gethostbyname(socket.gethostname())}</p>
    <p>Request count: {request_count}</p>
    <p>Time: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <p><a href="/api/info">View API Info</a></p>
    <p><a href="/api/health">Health Check</a></p>
    """

@app.route('/api/info')
def api_info():
    """API endpoint returning application information"""
    return jsonify({
        'name': APP_NAME,
        'version': APP_VERSION,
        'hostname': socket.gethostname(),
        'request_count': request_count
    })

@app.route('/api/health')
def health_check():
    """Health check endpoint for Kubernetes liveness and readiness probes"""
    return jsonify({
        'status': 'healthy',
        'time': datetime.datetime.now().isoformat(),
        'hostname': socket.gethostname()
    })

if __name__ == '__main__':
    # Start the Flask application
    port = int(os.environ.get('PORT', 5000))
    print(f"Starting {APP_NAME} v{APP_VERSION} on port {port}")
    app.run(host='0.0.0.0', port=port)
EOL

# Create requirements.txt - just the minimal dependencies needed
cat > app/requirements.txt << 'EOL'
Flask==2.2.3
EOL

# ===== STEP 2: Create a simple Dockerfile =====
cat > app/Dockerfile << 'EOL'
# Simple Dockerfile for Python Flask application
# 
# Key concepts:
# - FROM: Specifies the base image to use
# - WORKDIR: Sets the working directory inside the container
# - COPY: Copies files from host to container
# - RUN: Executes commands during the build process
# - EXPOSE: Documents which ports are intended to be published
# - CMD: Defines the default command to run when the container starts

# Use Python 3.9 slim image as base to keep the image size small
FROM python:3.9-slim

# Set working directory inside container
WORKDIR /app

# Copy requirements file and install dependencies
# (We copy this first to leverage Docker cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Document that the container will listen on port 5000
EXPOSE 5000

# Command to run when container starts
CMD ["python", "app.py"]
EOL

# ===== STEP 3: Create Kubernetes manifests =====

# Create namespace.yaml
# A namespace provides a scope for Kubernetes resources, allowing multiple teams to use the same cluster
cat > k8s/namespace.yaml << 'EOL'
apiVersion: v1
kind: Namespace
metadata:
  name: mini-demo
  labels:
    name: mini-demo
EOL

# Create configmap.yaml
# ConfigMaps allow you to decouple configuration from container images
cat > k8s/configmap.yaml << 'EOL'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: mini-demo
data:
  # These key-value pairs will be available as environment variables in the pods
  APP_NAME: "Kubernetes Mini Demo"
  APP_VERSION: "1.0.0"
EOL

# Create deployment.yaml
# A Deployment manages a set of identical Pods (replicas) ensuring declarative updates
cat > k8s/deployment.yaml << 'EOL'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: mini-demo
  labels:
    app: flask-app
spec:
  # Number of identical pod replicas to maintain
  replicas: 2
  
  # Selector defines how the Deployment finds which Pods to manage
  selector:
    matchLabels:
      app: flask-app
  
  # Pod template defines what each Pod should look like
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: flask-app
        # This refers to the image we'll build from our Dockerfile
        image: mini-k8s-demo:latest
        imagePullPolicy: Never  # Use local image (for Minikube)
        
        # Ports to expose from the container
        ports:
        - containerPort: 5000
          name: http
        
        # Environment variables from ConfigMap
        envFrom:
        - configMapRef:
            name: app-config
        
        # Resource limits and requests
        resources:
          requests:
            cpu: "100m"     # 0.1 CPU core
            memory: "64Mi"  # 64 MB of memory
          limits:
            cpu: "200m"     # 0.2 CPU core
            memory: "128Mi" # 128 MB of memory
        
        # Health checks to determine if container is alive and ready
        livenessProbe:
          httpGet:
            path: /api/health
            port: http
          initialDelaySeconds: 10
          periodSeconds: 30
        
        readinessProbe:
          httpGet:
            path: /api/health
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
EOL

# Create service.yaml
# A Service exposes an application running in Pods through a single, stable network endpoint
cat > k8s/service.yaml << 'EOL'
apiVersion: v1
kind: Service
metadata:
  name: flask-app
  namespace: mini-demo
  labels:
    app: flask-app
spec:
  # Service type: 
  # - ClusterIP: Internal only (default)
  # - NodePort: Exposes on Node IP at a static port
  # - LoadBalancer: Exposes externally using cloud provider's load balancer
  type: NodePort
  
  # Which pods to route traffic to (matches labels)
  selector:
    app: flask-app
  
  # Port mapping
  ports:
  - port: 80           # Port exposed by the service
    targetPort: 5000   # Port the container accepts traffic on
    nodePort: 30080    # Port on the node (range 30000-32767)
    protocol: TCP
EOL

# ===== STEP 4: Create a deployment script =====
cat > deploy.sh << 'EOL'
#!/bin/bash
# Simple script to deploy the application to Kubernetes

# Start with color definitions for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}===== KUBERNETES MINI DEMO DEPLOYMENT =====${NC}"

# Step 1: Ensure Minikube is running
echo -e "${GREEN}Checking if Minikube is running...${NC}"
if ! minikube status | grep -q "host: Running"; then
    echo "Starting Minikube..."
    minikube start
else
    echo "Minikube is already running"
fi

# Step 2: Configure Docker to use Minikube's Docker daemon
# This allows us to build images directly into Minikube's Docker registry
echo -e "${GREEN}Configuring Docker to use Minikube's Docker daemon...${NC}"
eval $(minikube docker-env)

# Step 3: Build the Docker image
echo -e "${GREEN}Building Docker image...${NC}"
cd ~/mini-k8s-demo/app
docker build -t mini-k8s-demo:latest .

# Step 4: Apply Kubernetes manifests in order
echo -e "${GREEN}Applying Kubernetes manifests...${NC}"
cd ~/mini-k8s-demo
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Step 5: Wait for deployment to be ready
echo -e "${GREEN}Waiting for deployment to be ready...${NC}"
kubectl -n mini-demo rollout status deployment/flask-app

# Step 6: Get the URL to access the application
echo -e "${GREEN}Getting application URL...${NC}"
minikube service flask-app -n mini-demo --url

echo -e "${BLUE}===== DEPLOYMENT COMPLETE =====${NC}"
echo "To view Kubernetes dashboard, run: minikube dashboard"
echo "To view application logs, run: kubectl -n mini-demo logs -l app=flask-app"
echo "To clean up resources, run: kubectl delete namespace mini-demo"
EOL

# Make the deployment script executable
chmod +x deploy.sh

# ===== STEP 5: Create script to explain Kubernetes concepts =====
cat > k8s-explained.md << 'EOL'
# Kubernetes Concepts Explained

## Why Kubernetes?

Docker provides containerization, but Kubernetes provides **orchestration** of containers. This means:

1. **Automated Deployment**: Deploy containers across multiple hosts
2. **Scaling**: Scale containers up or down based on demand
3. **Self-healing**: Restart or replace failed containers automatically
4. **Service Discovery**: Find and communicate with services dynamically
5. **Load Balancing**: Distribute traffic across container instances
6. **Rolling Updates**: Update applications without downtime

## Core Kubernetes Components

### Pod
- Smallest deployable unit in Kubernetes
- Contains one or more containers that share storage and network
- Usually one main application container per pod
- Think of it as a logical host for your container(s)

### Deployment
- Manages a set of identical pods (replicas)
- Ensures the specified number of pods are running
- Handles rolling updates and rollbacks
- Maintains pod health and replaces failed pods

### Service
- Provides stable network endpoint to access pods
- Pods are ephemeral (temporary) but services are persistent
- Types:
  - ClusterIP: Internal only
  - NodePort: Exposes on Node IP at static port
  - LoadBalancer: Exposes externally using cloud provider's load balancer

### ConfigMap & Secret
- ConfigMap: Stores non-sensitive configuration
- Secret: Stores sensitive data (passwords, tokens, keys)
- Both decouple configuration from container images

## Kubernetes Architecture

### Control Plane Components
- **API Server**: Front-end to the control plane, all communication goes through it
- **etcd**: Key-value store that holds all cluster data
- **Scheduler**: Assigns pods to nodes
- **Controller Manager**: Runs controller processes (e.g., deployment controller)

### Node Components
- **kubelet**: Agent that ensures containers are running in a pod
- **kube-proxy**: Maintains network rules on nodes
- **Container Runtime**: Software responsible for running containers (e.g., Docker)

## Kubernetes vs Docker

| Feature | Docker | Kubernetes |
|---------|--------|------------|
| Focus | Creating and running containers | Orchestrating containers at scale |
| Scale | Single host or small-scale | Multi-host clusters |
| Self-healing | Limited | Automatic pod replacement |
| Load Balancing | Basic | Advanced internal and external |
| Scaling | Manual | Automatic horizontal scaling |
| Updates | Manual | Automated rolling updates |
EOL

echo "Simplified Kubernetes demo environment created successfully!"
echo "To deploy the application, run: ~/mini-k8s-demo/deploy.sh"
echo "Check ~/mini-k8s-demo/k8s-explained.md for Kubernetes concepts explained"
