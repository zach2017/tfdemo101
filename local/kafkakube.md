A real application it is — I'll give you Python, since it's the quickest to run and the failover behavior is easy to see in the output. This connects from your host to the external NodePort listeners we set up.

## 1. Install the Client Library

`confluent-kafka` is the most robust Python client (wraps the C library, same one the CLI uses):

```bash
pip install confluent-kafka
```

## 2. The Producer

This sends a steady stream and — crucially — handles broker failure gracefully so you can watch failover. Create `producer.py`:

```python
#!/usr/bin/env python3
"""Kafka producer — sends a steady stream, survives broker failure."""
import time
import json
import signal
import sys
from confluent_kafka import Producer

# All three external NodePorts — client discovers the rest from any one
BOOTSTRAP = "127.0.0.1:31090,127.0.0.1:31091,127.0.0.1:31092"
TOPIC = "my-topic"

conf = {
    "bootstrap.servers": BOOTSTRAP,
    # Wait for all in-sync replicas to ack — this is what makes
    # writes survive a broker loss without data loss
    "acks": "all",
    # Retry transparently when a broker disappears
    "retries": 10,
    "retry.backoff.ms": 500,
    # Detect dead brokers reasonably fast
    "socket.timeout.ms": 10000,
    "message.timeout.ms": 30000,
}

producer = Producer(conf)
running = True

def shutdown(sig, frame):
    global running
    print("\nFlushing and exiting...")
    running = False

signal.signal(signal.SIGINT, shutdown)

def delivery_report(err, msg):
    """Called per message — shows which broker/partition took it."""
    if err is not None:
        print(f"  ✗ DELIVERY FAILED: {err}")
    else:
        print(f"  ✓ partition {msg.partition()} offset {msg.offset()}")

count = 0
while running:
    count += 1
    payload = json.dumps({
        "id": count,
        "timestamp": time.time(),
        "message": f"event number {count}",
    })

    try:
        producer.produce(
            TOPIC,
            key=str(count),         # key determines partition — spreads load
            value=payload,
            callback=delivery_report,
        )
        # Serve delivery callbacks
        producer.poll(0)
        print(f"Sent #{count}")
    except BufferError:
        print("  Queue full, waiting...")
        producer.poll(1)

    time.sleep(1)

producer.flush(10)
print(f"Done. Sent {count} messages.")
```

Key things here: `acks="all"` plus the cluster's `min.insync.replicas=2` is the combination that guarantees no data loss on a single broker failure. The `retries` config makes the producer ride through a broker disappearing — you'll see deliveries pause then resume rather than crash. And using a `key` distributes messages across partitions (load balancing) deterministically.

## 3. The Consumer

This reads continuously and shows which partition each message came from — so you can see consumption spread across brokers. Create `consumer.py`:

```python
#!/usr/bin/env python3
"""Kafka consumer — reads continuously, shows partition distribution."""
import json
import signal
import sys
from confluent_kafka import Consumer, KafkaError

BOOTSTRAP = "127.0.0.1:31090,127.0.0.1:31091,127.0.0.1:31092"
TOPIC = "my-topic"

conf = {
    "bootstrap.servers": BOOTSTRAP,
    "group.id": "my-consumer-group",
    # Start from beginning if no committed offset exists
    "auto.offset.reset": "earliest",
    # Commit progress automatically
    "enable.auto.commit": True,
    "auto.commit.interval.ms": 5000,
}

consumer = Consumer(conf)
consumer.subscribe([TOPIC])
running = True

def shutdown(sig, frame):
    global running
    running = False

signal.signal(signal.SIGINT, shutdown)

# Track how many messages came from each partition
partition_counts = {}

print(f"Consuming from {TOPIC}... (Ctrl+C to stop)\n")
try:
    while running:
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                continue
            else:
                print(f"Error: {msg.error()}")
                continue

        data = json.loads(msg.value().decode("utf-8"))
        p = msg.partition()
        partition_counts[p] = partition_counts.get(p, 0) + 1

        print(f"[partition {p}] id={data['id']:<5} "
              f"| counts so far: {dict(sorted(partition_counts.items()))}")
finally:
    print(f"\nFinal partition distribution: {dict(sorted(partition_counts.items()))}")
    consumer.close()
```

The `partition_counts` running tally is the load-balancing made visible — over time you'll see roughly even counts across all 6 partitions, confirming messages are spread across brokers rather than piling onto one.

## 4. Run the Failover Demo

Three terminals:

**Terminal 1 — consumer:**
```bash
python consumer.py
```

**Terminal 2 — producer:**
```bash
python producer.py
```
You'll see a steady `Sent #1, #2, ...` with delivery confirmations showing different partitions.

**Terminal 3 — kill a broker mid-stream:**
```bash
kubectl delete pod my-kafka-controller-1
```

Now watch Terminal 2. You'll likely see a brief pause or a couple of retry messages as the client detects the dead broker and re-fetches metadata — then deliveries resume, landing on the surviving brokers. No crash, no lost messages. When Kubernetes reschedules the broker (~30–60s), it rejoins and re-syncs. The consumer in Terminal 1 keeps printing throughout, and the final partition tally shows the load stayed balanced.

If you have Grafana open from earlier, the under-replicated-partitions panel spikes when the broker dies and settles back to zero once it re-syncs — the same event seen from the cluster's side.

## 5. Scaling Consumers (Bonus Load Balancing)

To see consumer-group load balancing, run a **second** consumer in another terminal:
```bash
python consumer.py
```
Because both share `group.id="my-consumer-group"`, Kafka automatically splits the 6 partitions between them — roughly 3 each. Each instance's tally will show only the partitions it was assigned. Kill one consumer and the other automatically picks up all 6 again (a "rebalance"). That's the consumer side of failover, complementing the broker side.

---

A couple of practical notes. If the producer can send but the consumer reads nothing, it's usually the group's offset — delete and recreate with a fresh `group.id`, or the topic genuinely has no new messages. And if you get connection errors from the host, it's back to the advertised-listener setup from before: `--list` working but produce/consume hanging is the signature of brokers advertising an address your host can't reach.

This is the complete picture now: a kind cluster, multi-broker Kafka with replication, external access, real producer/consumer apps, failover that survives broker loss, and monitoring to watch it happen.
