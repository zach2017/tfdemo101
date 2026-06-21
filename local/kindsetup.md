
## 1. Prerequisites

Make sure Docker is installed and running:
```bash
docker --version
```

## 2. Install kind

**Linux:**
```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

**macOS:**
```bash
brew install kind
```

**Windows (PowerShell):**
```powershell
curl.exe -Lo kind-windows-amd64.exe https://kind.sigs.k8s.io/dl/v0.23.0/kind-windows-amd64
Move-Item .\kind-windows-amd64.exe c:\some-dir-in-your-PATH\kind.exe
```

## 3. Install kubectl

**Linux:**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

**macOS:**
```bash
brew install kubectl
```

## 4. Create a Cluster

**Single-node:**
```bash
kind create cluster --name my-cluster
```

**Multi-node** (create `config.yaml`):
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
```
```bash
kind create cluster --name my-cluster --config config.yaml
```

## 5. Verify

```bash
kubectl cluster-info --context kind-my-cluster
kubectl get nodes
```

## Common Commands

```bash
kind get clusters              # list clusters
kind delete cluster --name my-cluster   # delete cluster
kubectl get pods -A            # all pods
```


# minikube + Multi-Node + Ingress

## 1. Install minikube

**Linux:**
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

**macOS:**
```bash
brew install minikube
```

**Windows (PowerShell as Admin):**
```powershell
choco install minikube
```

## 2. Start a Multi-Node Cluster

```bash
minikube start --driver=docker --nodes 3
```

This creates 1 control-plane + 2 worker nodes. Verify:
```bash
kubectl get nodes
```
```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   2m    v1.30.0
minikube-m02   Ready    <none>          1m    v1.30.0
minikube-m03   Ready    <none>          1m    v1.30.0
```

## 3. Enable Ingress

```bash
minikube addons enable ingress
```

> ⚠️ **Note:** The ingress addon officially supports the Docker driver primarily on Linux. On macOS/Windows with Docker, you'll need `minikube tunnel` (step 6) to reach it.

Verify the controller is running:
```bash
kubectl get pods -n ingress-nginx
```

## 4. Deploy a Sample App

Create `app.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-svc
spec:
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 8080
```

Apply it:
```bash
kubectl apply -f app.yaml
```

## 5. Create the Ingress

Create `ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: hello.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-svc
            port:
              number: 80
```

Apply it:
```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

## 6. Access the App

**Linux:** Map the hostname to the minikube IP:
```bash
echo "$(minikube ip) hello.local" | sudo tee -a /etc/hosts
curl http://hello.local
```

**macOS/Windows:** Run a tunnel in a separate terminal (keep it open):
```bash
minikube tunnel
```
Then add `127.0.0.1 hello.local` to your hosts file and `curl http://hello.local`.

You should see:
```
Hello, world!
Version: 1.0.0
Hostname: hello-app-xxxxx
```

## Useful Commands

```bash
minikube node list                    # list nodes
minikube node add                     # add a worker node
minikube dashboard                    # web UI
minikube stop                         # stop cluster
minikube delete                       # delete cluster
kubectl describe ingress hello-ingress  # debug ingress
```

---

A few notes worth flagging: pod scheduling across nodes is automatic, but if you want to *see* pods land on different nodes, scale up replicas (`kubectl scale deployment hello-app --replicas=6`) and check with `kubectl get pods -o wide`. Also, on macOS/Windows the Docker driver runs everything inside a VM, so `minikube ip` won't be directly reachable — that's why the tunnel is needed.


Switching to **kind** for TLS requires one extra piece kind doesn't include by default: an ingress controller. minikube gave you that as an addon, but with kind you install it manually and configure port mappings up front. Here's the full flow.

## 1. Create a Cluster with Ingress Port Mappings

kind needs ports 80/443 exposed to the host *at cluster creation time*. Create `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
```

Create it:
```bash
kind create cluster --name my-cluster --config kind-config.yaml
```

The `ingress-ready=true` label and port mappings are what let the ingress controller bind to the host. If your cluster already exists without these, you'll need to delete and recreate it — port mappings can't be added after the fact.

## 2. Install the NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Wait for it to be ready:
```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

This is the kind-specific manifest — it's pre-configured to use the `ingress-ready` node and host ports, which the generic manifest doesn't do.

## 3. Deploy the App

Same `app.yaml` as before (unchanged):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-svc
spec:
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 8080
```
```bash
kubectl apply -f app.yaml
```

## 4. Generate the Cert and TLS Secret

Identical to before:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=hello.local/O=hello.local" \
  -addext "subjectAltName=DNS:hello.local"

kubectl create secret tls hello-tls --cert=tls.crt --key=tls.key
```

## 5. Apply the TLS Ingress

Same `ingress.yaml` with the `tls:` block:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - hello.local
    secretName: hello-tls
  rules:
  - host: hello.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-svc
            port:
              number: 80
```
```bash
kubectl apply -f ingress.yaml
```

## 6. Access It

The key difference from minikube: kind maps ports straight to **localhost**, so no `minikube tunnel` and no `minikube ip`. Just point the hostname at `127.0.0.1`:

```bash
echo "127.0.0.1 hello.local" | sudo tee -a /etc/hosts
```

Then:
```bash
curl -k https://hello.local
```

You should see the `Hello, world!` output. Verify the cert:
```bash
curl -kv https://hello.local 2>&1 | grep -i "subject:"
```

## kind vs minikube — What Changed

The mechanics that differ: with kind, port mappings are baked in at creation (the `extraPortMappings` block) and the cluster is reachable on `127.0.0.1` directly, whereas minikube needed the addon plus a tunnel on macOS/Windows. The ingress controller is a manual `kubectl apply` instead of `minikube addons enable`, and it requires the kind-specific manifest. Everything downstream — the app, the cert, the TLS secret, the ingress resource — is identical across both.

Force-SSL-redirect and the cert-manager production path both work exactly the same as I described for minikube.
This is a meaningful step up — running Kafka on Kubernetes with replication and failover. Let me set this up with Helm on your kind cluster. I'll flag the kind-specific constraints as we go, since a few things differ from a cloud cluster.

## 1. Add the Bitnami Helm Repo

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

> **Heads up:** As of mid-2025 Bitnami moved most free chart images to a `bitnamilegacy` repo and changed their catalog. If you hit image-pull errors, that's why — I'll note the workaround at the end. The Bitnami Kafka chart is still the most straightforward path, so let's start there.

## 2. Create the Kafka Values File

This is where failover and load balancing come from — KRaft mode with multiple brokers and a replication factor that survives a node going down. Create `kafka-values.yaml`:

```yaml
# KRaft mode (no ZooKeeper) — combined controller+broker
kraft:
  enabled: true

# 3 brokers across your 3 nodes = failover
controller:
  replicas: 3
  # Spread brokers across different nodes
  podAntiAffinityPreset: hard
  resources:
    requests:
      cpu: 250m
      memory: 512Mi

# Replication: data survives 1 broker loss
extraConfig: |
  offsets.topic.replication.factor=3
  transaction.state.log.replication.factor=3
  transaction.state.log.min.isr=2
  default.replication.factor=3
  min.insync.replicas=2

# Internal load balancing across brokers
service:
  type: ClusterIP

# Persistence per broker
persistence:
  enabled: true
  size: 2Gi

listeners:
  client:
    protocol: PLAINTEXT
```

The key settings: `replicas: 3` gives three brokers, `podAntiAffinityPreset: hard` forces each onto a different node (true failover — losing a node loses only one broker), and `min.insync.replicas=2` with `default.replication.factor=3` means a topic stays available and writable even with one broker down.

## 3. Install Kafka

```bash
helm install my-kafka bitnami/kafka -f kafka-values.yaml
```

Watch the brokers come up:
```bash
kubectl get pods -w -l app.kubernetes.io/name=kafka
```

Wait until all three show `Running`:
```
my-kafka-controller-0   1/1   Running
my-kafka-controller-1   1/1   Running
my-kafka-controller-2   1/1   Running
```

Confirm they landed on different nodes (this is your failover guarantee):
```bash
kubectl get pods -o wide -l app.kubernetes.io/name=kafka
```

## 4. How Load Balancing Works Here

Kafka's load balancing isn't an external LB — it's built into the protocol. The headless service gives clients the broker list, then:

- **Producers** distribute messages across partitions, which live on different brokers.
- **Partition leadership** is spread across brokers, so read/write load is naturally balanced.
- **Consumer groups** split partitions among consumers automatically.

So to actually get load balancing, you create a topic with multiple partitions:

```bash
kubectl exec -it my-kafka-controller-0 -- \
  kafka-topics.sh --create \
  --topic my-topic \
  --partitions 6 \
  --replication-factor 3 \
  --bootstrap-server localhost:9092
```

6 partitions × replication 3 = load spread across brokers, each partition replicated so any single broker can fail.

## 5. Test Failover

Produce some messages, then kill a broker and confirm the topic still works:

```bash
# Terminal 1 — produce
kubectl exec -it my-kafka-controller-0 -- \
  kafka-console-producer.sh \
  --topic my-topic \
  --bootstrap-server localhost:9092

# Terminal 2 — kill a broker
kubectl delete pod my-kafka-controller-1

# Back in Terminal 1 — keep typing messages; they still send
# Terminal 3 — consume, all messages present
kubectl exec -it my-kafka-controller-0 -- \
  kafka-console-consumer.sh \
  --topic my-topic \
  --from-beginning \
  --bootstrap-server localhost:9092
```

Kubernetes reschedules the killed broker automatically, and because `min.insync.replicas=2`, the cluster never lost the ability to serve writes.

## 6. Check Replication Health

```bash
kubectl exec -it my-kafka-controller-0 -- \
  kafka-topics.sh --describe \
  --topic my-topic \
  --bootstrap-server localhost:9092
```

Look at the `Isr` (in-sync replicas) column — each partition should list multiple broker IDs. That's your failover working.

---

## Two kind-specific cautions

**Resources:** Three Kafka brokers on a single Docker host (which is what kind is) is heavy. If pods get stuck `Pending` or `OOMKilled`, your Docker VM needs more memory — bump Docker Desktop to 6–8 GB, or drop to `controller.replicas: 1` for a functional-but-not-HA test setup.

**If image pulls fail** (the Bitnami change I mentioned): add this to the values file to point at the legacy images:
```yaml
global:
  imageRegistry: docker.io
image:
  repository: bitnamilegacy/kafka
```
Or pin to a known-good older chart version with `helm install my-kafka bitnami/kafka --version 30.0.0 -f kafka-values.yaml`. If you run into a specific error, paste it and I'll pin the exact fix.

---
Both, then. External access first (you need it to connect a real client), then monitoring to see the load. External access is the more involved piece — Kafka's protocol makes it trickier than a normal HTTP service, and I'll explain why.

## Part 1: External Access

### Why Kafka external access is different

A normal service, you expose one endpoint. Kafka can't work that way: a client connects to *any* broker, gets back the **advertised addresses** of all brokers, then connects directly to the specific broker holding the partition it wants. So every broker needs its own externally reachable address. One shared endpoint won't do — if all three brokers advertised the same address, the client could never reach a specific partition leader.

With kind, the clean way is a NodePort per broker mapped through to localhost.

### Step 1: Add NodePort mappings to the cluster

NodePorts need to be reachable from your host, so they have to be in the kind config's `extraPortMappings`. If your cluster is already running, this means **recreating it** (port mappings can't be added live). Update `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  # Kafka external NodePorts — one per broker
  - containerPort: 31090
    hostPort: 31090
    protocol: TCP
  - containerPort: 31091
    hostPort: 31091
    protocol: TCP
  - containerPort: 31092
    hostPort: 31092
    protocol: TCP
- role: worker
- role: worker
```

```bash
kind delete cluster --name my-cluster
kind create cluster --name my-cluster --config kind-config.yaml
```

(Then re-run the ingress controller install from before if you still want it.)

### Step 2: Update Kafka values for external listeners

This is the part that makes Kafka advertise reachable addresses. Update `kafka-values.yaml` — add the `externalAccess` block and external listener config:

```yaml
kraft:
  enabled: true

controller:
  replicas: 3
  podAntiAffinityPreset: hard
  resources:
    requests:
      cpu: 250m
      memory: 512Mi

extraConfig: |
  offsets.topic.replication.factor=3
  transaction.state.log.replication.factor=3
  transaction.state.log.min.isr=2
  default.replication.factor=3
  min.insync.replicas=2

persistence:
  enabled: true
  size: 2Gi

listeners:
  client:
    protocol: PLAINTEXT
  external:
    protocol: PLAINTEXT

# External access via NodePort — each broker gets its own port
externalAccess:
  enabled: true
  controller:
    service:
      type: NodePort
      nodePorts:
      - 31090
      - 31091
      - 31092
      # Brokers advertise localhost so your host client can reach them
      domain: 127.0.0.1
```

The critical line is `domain: 127.0.0.1`. That's what each broker advertises back to clients. Because kind maps those NodePorts to localhost, a client on your machine connecting to `127.0.0.1:31090` reaches broker 0, `:31091` broker 1, and so on.

### Step 3: Upgrade the release

```bash
helm upgrade my-kafka bitnami/kafka -f kafka-values.yaml
```

Wait for the pods to cycle, then check the NodePort services exist:
```bash
kubectl get svc -l app.kubernetes.io/name=kafka
```
You'll see `my-kafka-controller-0-external`, `-1-external`, `-2-external` as NodePort services.

### Step 4: Connect from your host

You need a Kafka client locally. Quickest is to download the CLI tools:
```bash
# Requires Java 17+
curl -O https://downloads.apache.org/kafka/3.7.0/kafka_2.13-3.7.0.tgz
tar -xzf kafka_2.13-3.7.0.tgz
cd kafka_2.13-3.7.0
```

Test the connection from your host:
```bash
bin/kafka-topics.sh --list --bootstrap-server 127.0.0.1:31090
```

Produce and consume from your machine:
```bash
# Produce
bin/kafka-console-producer.sh \
  --topic my-topic \
  --bootstrap-server 127.0.0.1:31090

# Consume
bin/kafka-console-consumer.sh \
  --topic my-topic \
  --from-beginning \
  --bootstrap-server 127.0.0.1:31090
```

If `--list` works but producing hangs, it's almost always the advertised-address setting — the client reached the bootstrap broker but couldn't reach the partition leader's advertised address. Double-check `domain: 127.0.0.1` and that all three NodePorts are mapped.

---

## Part 2: Monitoring (Prometheus + Grafana)

Now let's see the broker load and partition distribution visually.

### Step 1: Enable Kafka metrics

Add JMX metrics export to `kafka-values.yaml`:

```yaml
metrics:
  jmx:
    enabled: true
```

```bash
helm upgrade my-kafka bitnami/kafka -f kafka-values.yaml
```

This adds a JMX exporter sidecar to each broker that exposes Prometheus-format metrics.

### Step 2: Install the kube-prometheus-stack

This bundles Prometheus, Grafana, and Alertmanager in one chart:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace
```

Wait for it:
```bash
kubectl get pods -n monitoring -w
```

### Step 3: Tell Prometheus to scrape Kafka

The stack uses `ServiceMonitor` resources to discover scrape targets. Create `kafka-servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-metrics
  namespace: monitoring
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kafka
  namespaceSelector:
    any: true
  endpoints:
  - port: metrics
    interval: 30s
```

```bash
kubectl apply -f kafka-servicemonitor.yaml
```

The `release: monitoring` label is what makes the kube-prometheus-stack pick it up — without it, Prometheus ignores the ServiceMonitor.

### Step 4: Open Grafana

Get the admin password:
```bash
kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

Port-forward to reach it:
```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Open `http://localhost:3000`, log in as `admin` with that password.

### Step 5: Import a Kafka dashboard

In Grafana: **Dashboards → New → Import**, then enter dashboard ID **`7589`** (Kafka Exporter Overview) or **`11962`** (Kafka cluster via JMX). Select the Prometheus data source and import.

You'll now see per-broker throughput, partition counts per broker, under-replicated partitions, and consumer lag — which is exactly how you visually confirm the load balancing (partitions spread across brokers) and failover (under-replicated count spikes then recovers when you kill a broker).

---

## Putting it together — the failover demo with monitoring

With both pieces live, here's the satisfying test:

1. Open Grafana, watch the partition distribution panel.
2. From your **host machine**, produce a steady stream of messages.
3. `kubectl delete pod my-kafka-controller-1`.
4. Watch in Grafana: under-replicated partitions spike, then recover as the broker reschedules and re-syncs. Your producer never stops.

That's the whole stack proven end to end: external client → load-balanced across brokers → survives broker loss → visible in monitoring.

---

Two things worth noting given this is kind: the full stack (3 Kafka brokers + JMX sidecars + Prometheus + Grafana) is genuinely RAM-hungry — realistically 8 GB+ on your Docker VM, and if things go `Pending` that's the cause. And the NodePort/advertised-address setup is the single most error-prone part; if external producing misbehaves, that's the first place to look.
