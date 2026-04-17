# CloudNativePG Demo on Docker Desktop

cloudnativepg demo

Run a PostgreSQL 18 cluster on Docker Desktop's built-in Kubernetes using the [CloudNativePG](https://cloudnative-pg.io/) operator.

## Prerequisites

- **Docker Desktop** with Kubernetes enabled (Settings → Kubernetes → Enable Kubernetes)
- **kubectl** configured to use the `docker-desktop` context

Verify your setup:

```bash
kubectl config use-context docker-desktop
kubectl get nodes
```

## 1. Install the CloudNativePG Operator

Apply the operator manifest using **server-side apply** (required because some CRDs exceed the client-side annotation size limit):

```bash
kubectl apply --server-side -f cnpg-1.29.0.yaml
```

Wait for the operator to be ready:

```bash
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

Confirm the CRDs are registered:

```bash
kubectl get crd | grep postgresql.cnpg.io
```

## 2. Deploy the PostgreSQL 18 Cluster

```bash
kubectl apply -f new-launch.yaml
```

This creates a 3-instance PostgreSQL 18 cluster named `pg18-cluster` in the `default` namespace with:

- 2 GiB storage per instance
- A bootstrap database `app` owned by user `app`
- Tuned `shared_buffers` and `max_connections`

## 3. Monitor Cluster Status

```bash
# Watch the cluster reach "Cluster in healthy state"
kubectl get cluster pg18-cluster -w

# Check individual pods
kubectl get pods -l cnpg.io/cluster=pg18-cluster
```

## 4. Get Cluster IP and Port

CNPG automatically creates three services for the cluster:

| Service | Purpose |
|---|---|
| `pg18-cluster-rw` | Read-write (primary only) |
| `pg18-cluster-ro` | Read-only (replicas only) |
| `pg18-cluster-r` | Read (any instance) |

List all services:

```bash
kubectl get svc -l cnpg.io/cluster=pg18-cluster
```

Get the ClusterIP and port for the read-write service:

```bash
kubectl get svc pg18-cluster-rw -o jsonpath='IP: {.spec.clusterIP}  Port: {.spec.ports[0].port}'
```

Get pod IPs of each instance:

```bash
kubectl get pods -l cnpg.io/cluster=pg18-cluster -o wide
```

Get endpoints (pod IP:port pairs backing the service):

```bash
kubectl get endpoints pg18-cluster-rw
```

**From inside the cluster**, other pods can connect using DNS — no port-forward needed:

```
pg18-cluster-rw.default.svc.cluster.local:5432   # primary (read-write)
pg18-cluster-ro.default.svc.cluster.local:5432   # replicas (read-only)
pg18-cluster-r.default.svc.cluster.local:5432    # any instance
```

**From outside the cluster** (your local machine), use port-forward:

```bash
kubectl port-forward svc/pg18-cluster-rw 5432:5432
```

## 5. Install psql Client

### macOS

```bash
# Using Homebrew
brew install libpq
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Or install the full PostgreSQL (includes psql)
brew install postgresql@18
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y postgresql-client
```

### Using a psql Pod Inside the Cluster (no local install needed)

```bash
kubectl run psql-client --rm -it --image=postgres:18 --restart=Never -- \
  psql -h pg18-cluster-rw.default.svc.cluster.local -U app -d app
# Enter password: PgApp2026!
```

## 6. Connect and Test

The credentials are defined in the Secrets inside `new-launch.yaml`.
Values in `data:` are **base64-encoded**; the actual (decoded) credentials are:

| Secret | Username | Password |
|---|---|---|
| `pg18-cluster-app-user` | `app` | `PgApp2026!` |
| `pg18-cluster-superuser` | `postgres` | `PgSuper2026!` |

Decode passwords from the cluster:

```bash
kubectl get secret pg18-cluster-app-user -o jsonpath='{.data.password}' | base64 -d
kubectl get secret pg18-cluster-superuser -o jsonpath='{.data.password}' | base64 -d
```

### Connect from Local Machine

```bash
# Start port-forward in the background
kubectl port-forward svc/pg18-cluster-rw 5432:5432 &

# Connect as app user
psql -h 127.0.0.1 -U app -d app
# Enter password: PgApp2026!

# Connect as superuser
psql -h 127.0.0.1 -U postgres -d app
# Enter password: PgSuper2026!
```

### Why `psql -h 10.96.128.76` Fails in a Shell Script

`10.96.128.76` is the `ClusterIP` of the Kubernetes service `pg18-cluster-rw`.
That IP is reachable only from inside the Kubernetes cluster network.
If you run a shell script on your host machine, `psql -h 10.96.128.76 -U postgres -d app`
will usually fail because Docker Desktop does not expose Kubernetes `ClusterIP`
services directly to the host network.

Use one of these two patterns instead:

#### Option 1: Run `psql` from your local shell via port-forward

```bash
kubectl port-forward svc/pg18-cluster-rw 5432:5432
```

Then connect through localhost:

```bash
PGPASSWORD='PgSuper2026!' psql -h 127.0.0.1 -p 5432 -U postgres -d app
```

Example shell script:

```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl port-forward svc/pg18-cluster-rw 5432:5432 >/tmp/pg18-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID' EXIT

until pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; do
  sleep 1
done

PGPASSWORD='PgSuper2026!' psql -h 127.0.0.1 -p 5432 -U postgres -d app -c 'select version();'
```

#### Option 2: Run `psql` inside the cluster

If the shell script runs in a pod, or if you start a temporary client pod, use the
service DNS name instead of the `ClusterIP`:

```bash
PGPASSWORD='PgSuper2026!' psql -h pg18-cluster-rw.default.svc.cluster.local -p 5432 -U postgres -d app
```

Temporary client pod example:

```bash
kubectl run psql-client --rm -it --image=postgres:18 --restart=Never \
  --env="PGPASSWORD=PgSuper2026!" -- \
  psql -h pg18-cluster-rw.default.svc.cluster.local -p 5432 -U postgres -d app
```

Summary:

- Host shell script: `kubectl port-forward` + `psql -h 127.0.0.1`
- In-cluster shell script: `psql -h pg18-cluster-rw.default.svc.cluster.local`
- Do not use the service `ClusterIP` from your host shell

### Verify the Cluster

Once connected via psql, run these commands to verify:

```sql
-- Check PostgreSQL version
SELECT version();

-- Check current user and database
SELECT current_user, current_database();

-- List databases
\l

-- Check replication status (as superuser)
SELECT client_addr, state, sent_lsn, write_lsn FROM pg_stat_replication;

-- Check cluster nodes
SELECT * FROM pg_stat_activity WHERE backend_type = 'client backend';

-- Create a test table
CREATE TABLE test (id serial PRIMARY KEY, msg text);
INSERT INTO test (msg) VALUES ('Hello from pg18-cluster!');
SELECT * FROM test;
DROP TABLE test;
```

## 7. Cleanup

```bash
kubectl delete -f new-launch.yaml
kubectl delete --server-side -f cnpg-1.29.0.yaml
```

## Other Manifests

| File | Description |
|---|---|
| `cluster-example.yaml` | Minimal 3-instance cluster (default PG image) |
| `new.yaml` | Production-style single-instance PG 15 cluster with tuned parameters, affinity rules, backups, and monitoring |
| `new-launch.yaml` | PostgreSQL 18 cluster for Docker Desktop |
| `cnpg-1.29.0.yaml` | CloudNativePG operator v1.29.0 |
