# Heartbeats in Distributed Systems

**Arpit Bhayani**
*curious, tinkerer, and explorer*

[Blogs](https://arpitbhayani.me/blogs) | [Papershelf](https://arpitbhayani.me/papershelf) | [Bookshelf](https://arpitbhayani.me/bookshelf) | [Courses](https://arpitbhayani.me/courses) | [Talks](https://arpitbhayani.me/talks)

---

In distributed systems, one of the fundamental challenges is knowing whether a node or service is alive and functioning properly. Unlike monolithic applications, where everything runs in a single process, distributed systems span multiple machines, networks, and data centers. This becomes even more glaring when the nodes are geographically separated. This is where heartbeat mechanisms come into play.

Imagine a cluster of servers working together to process millions of requests per day. If one server silently crashes, how quickly can the system detect this failure and react? How do we distinguish between a truly dead server and one that is just temporarily slow due to network congestion? These questions form the core of why heartbeat mechanisms matter.

## What are Heartbeat Messages

At its most basic level, a heartbeat is a periodic signal sent from one component in a distributed system to another to indicate that the sender is still alive and functioning. Think of it as a simple message that says “I am alive!”

Heartbeat messages are typically small and lightweight, often containing just a timestamp, a sequence number, or an identifier. The key characteristic is that they are sent regularly at fixed intervals, creating a predictable pattern that other components can monitor.

The mechanism works through a simple contract between two parties: the sender and the receiver. The sender commits to broadcasting its heartbeat at regular intervals, say every 2 seconds. The receiver monitors these incoming heartbeats and maintains a record of when the last heartbeat was received. If the receiver does not hear from the sender within an expected timeframe, it can reasonably assume something has gone wrong.

```python
class HeartbeatSender:  
    def __init__(self, interval_seconds):  
        self.interval = interval_seconds  
        self.sequence_number = 0

    def send_heartbeat(self, target):  
        message = {  
            'node_id': self.get_node_id(),  
            'timestamp': time.time(),  
            'sequence': self.sequence_number  
        }  
        send_to(message, target)  
        self.sequence_number += 1

    def run(self):  
        while True:  
            self.send_heartbeat(target_node)  
            time.sleep(self.interval)
```

When a node crashes, stops responding, or becomes isolated due to network partitions, the heartbeats stop arriving. The monitoring system can then take appropriate action, such as removing the failed node from a load balancer pool, redirecting traffic to healthy nodes, or triggering failover procedures.

## Core Components of Heartbeat Systems

The first component is the **heartbeat sender**. This is the node or service that periodically generates and transmits heartbeat signals. In most implementations, the sender runs on a separate thread or as a background task to avoid interfering with the primary application logic.

The second component is the **heartbeat receiver or monitor**. This component listens for incoming heartbeats and tracks when each heartbeat was received. The monitor maintains state about all the nodes it is tracking, typically storing the timestamp of the last received heartbeat for each node. When evaluating node health, the monitor compares the current time against the last received heartbeat to determine if a node should be considered failed.

```python
class HeartbeatMonitor:  
    def __init__(self, timeout_seconds):  
        self.timeout = timeout_seconds  
        self.last_heartbeats = {}  
        
    def receive_heartbeat(self, message):  
        node_id = message['node_id']  
        self.last_heartbeats[node_id] = {  
            'timestamp': message['timestamp'],  
            'sequence': message['sequence'],  
            'received_at': time.time()  
        }  
        
    def check_node_health(self, node_id):  
        if node_id not in self.last_heartbeats:  
            return False  
            
        last_heartbeat_time = self.last_heartbeats[node_id]['received_at']  
        time_since_heartbeat = time.time() - last_heartbeat_time  
        
        return time_since_heartbeat < self.timeout  
        
    def get_failed_nodes(self):  
        failed_nodes = []  
        current_time = time.time()  
        
        for node_id, data in self.last_heartbeats.items():  
            if current_time - data['received_at'] > self.timeout:  
                failed_nodes.append(node_id)  
                
        return failed_nodes
```

The third parameter is the **heartbeat interval**, which determines how frequently heartbeats are sent. This interval represents a fundamental trade-off in distributed systems. Sending heartbeats too frequently, we waste network bandwidth and CPU cycles. Send them too infrequently, and we will be slow to detect failures. Most systems use intervals ranging from 1 to 10 seconds, depending on the application requirements and network characteristics.

The fourth one is the **timeout or failure threshold**. This defines how long the monitor will wait without receiving a heartbeat before declaring a node as failed.

Note, the timeout must be carefully chosen to balance two competing concerns: fast failure detection versus tolerance for temporary network delays or processing pauses. A typical rule of thumb is to set the timeout to at least 2 to 3 times the heartbeat interval, allowing for some missed heartbeats before declaring failure.

## Deciding Heartbeat Intervals and Timeouts

When a system uses very short intervals, such as sending heartbeats every 500 milliseconds, it can detect failures quickly. However, this comes at a cost. Each heartbeat consumes network bandwidth, and in a large cluster with hundreds or thousands of nodes, the cumulative traffic can become significant. Additionally, very short intervals make the system more sensitive to transient issues like brief network congestion or garbage collection pauses.

> Consider a system with 1000 nodes where each node sends heartbeats to a central monitor every 500 milliseconds. This results in 2000 heartbeat messages per second just for health monitoring. In a busy production environment, this overhead can interfere with actual application traffic.

Conversely, if the heartbeat interval is too long, say 30 seconds, the system becomes sluggish in detecting failures. A node could crash, but the system would not notice for 30 seconds or more. During this window, requests might continue to be routed to the failed node, resulting in user-facing errors.

Similarly, the timeout value must also account for network characteristics. In a distributed system spanning multiple data centers, network latency varies. A heartbeat sent from a node in California to a monitor in Virginia might take 80 milliseconds under normal conditions, but could spike to 200 milliseconds during periods of congestion.

Hence, if the timeout is set too aggressively, these transient delays trigger false alarms.

A practical approach is to measure the actual round-trip time in the network and use that as a baseline. Many systems follow the rule that the timeout should be at least 10 times the round-trip time. For example, if the average round-trip time is 10 milliseconds, the timeout should be at least 100 milliseconds to account for variance.

```python
def calculate_timeout(round_trip_time_ms, heartbeat_interval_ms):  
    # Timeout is 10x the RTT  
    rtt_based_timeout = round_trip_time_ms * 10  
    
    # Timeout should also be at least 2-3x the heartbeat interval  
    interval_based_timeout = heartbeat_interval_ms * 3  
    
    # Use the larger of the two  
    return max(rtt_based_timeout, interval_based_timeout)
```

Another important consideration is the concept of multiple missed heartbeats before declaring failure. Rather than marking a node as dead after a single missed heartbeat, systems wait until several consecutive heartbeats are missed. This approach reduces false positives caused by packet loss or momentary delays.

For instance, if we send heartbeats every 2 seconds and require 3 missed heartbeats before declaring failure, a node would need to be unresponsive for at least 6 seconds before being marked as failed. This provides a good balance between quick failure detection and tolerance for transient issues.

## Push vs Pull Heartbeat Models

Heartbeat mechanisms can be implemented using two different communication models: push and pull.

In a **push model**, the monitored node actively sends heartbeat messages to the monitoring system at regular intervals. The node takes responsibility for broadcasting its own health status. The monitored service simply runs a background thread that periodically sends a heartbeat message.

```python
class PushHeartbeat:  
    def __init__(self, monitor_address, interval):  
        self.monitor_address = monitor_address  
        self.interval = interval  
        self.running = False  
        
    def start(self):  
        self.running = True  
        self.heartbeat_thread = threading.Thread(target=self._send_loop)  
        self.heartbeat_thread.daemon = True  
        self.heartbeat_thread.start()  
        
    def _send_loop(self):  
        while self.running:  
            try:  
                self._send_heartbeat()  
            except Exception as e:  
                logging.error(f"Failed to send heartbeat: {e}")  
            time.sleep(self.interval)  
            
    def _send_heartbeat(self):  
        message = {  
            'node_id': self.get_node_id(),  
            'timestamp': time.time(),  
            'status': 'alive'  
        }  
        requests.post(self.monitor_address, json=message)
```

The push model works well in many scenarios, but it has limitations. If the node itself becomes completely unresponsive or crashes, it obviously cannot send heartbeats. Additionally, in networks with strict firewall rules, the monitored nodes might not be able to initiate outbound connections to the monitoring system.

*   **Kubernetes Node Heartbeats**: Hadoop YARN NodeManagers push heartbeats to the ResourceManager
*   **Celery and Airflow workers**: push heartbeats to the scheduler

In a **pull model**, the monitoring system actively queries the nodes at regular intervals to check their health. Instead of waiting for heartbeats to arrive, the monitor reaches out and asks, “Are you alive?” The monitored services expose a health endpoint that responds to these queries.

```python
class PullHeartbeat:  
    def __init__(self, nodes, interval):  
        self.nodes = nodes  # List of nodes to monitor  
        self.interval = interval  
        self.health_status = {}  
        
    def start(self):  
        self.running = True  
        self.poll_thread = threading.Thread(target=self._poll_loop)  
        self.poll_thread.daemon = True  
        self.poll_thread.start()  
        
    def _poll_loop(self):  
        while self.running:  
            for node in self.nodes:  
                self._check_node(node)  
            time.sleep(self.interval)  
            
    def _check_node(self, node):  
        try:  
            response = requests.get(f"http://{node}/health", timeout=2)  
            if response.status_code == 200:  
                self.health_status[node] = {  
                    'alive': True,  
                    'last_check': time.time()  
                }  
            else:  
                self.mark_node_unhealthy(node)  
        except Exception as e:  
            self.mark_node_unhealthy(node)
```

The pull model provides more control to the monitoring system and can be more reliable in some scenarios. Since the monitor initiates the connection, it works better in environments with asymmetric network configurations. However, it also introduces additional load on the monitor, especially in large clusters where hundreds or thousands of nodes need to be polled regularly.

*   **Load balancers**: actively probe backend servers
*   **Prometheus**: pulls metrics endpoints on each target
*   **Redis Sentinel**: monitors and polls Redis instances with PING

By the way, many real-world systems use a hybrid approach that combines elements of both models. For example, nodes might send heartbeats proactively (push), but the monitoring system also periodically polls critical nodes (pull) as a backup mechanism. This redundancy improves overall reliability.

## Failure Detection Algorithms

While basic heartbeat mechanisms are effective, they struggle with the challenge of distinguishing between actual failures and temporary slowdowns. This is where more sophisticated failure detection algorithms come into play.

The simplest failure detection algorithm uses a **fixed timeout**. If no heartbeat is received within the specified timeout period, the node is declared failed. While easy to implement, this binary approach is inflexible and prone to false positives in networks with variable latency.

```python
class FixedTimeoutDetector:  
    def __init__(self, timeout):  
        self.timeout = timeout  
        self.last_heartbeats = {}  
        
    def is_node_alive(self, node_id):  
        if node_id not in self.last_heartbeats:  
            return False  
        
        elapsed = time.time() - self.last_heartbeats[node_id]  
        return elapsed < self.timeout
```

### Phi Accrual Failure Detection

A more sophisticated approach is the **phi accrual failure detector**, originally developed for the Cassandra database. Instead of providing a binary output (alive or dead), the phi accrual detector calculates a suspicion level on a continuous scale. The higher the suspicion value, the more likely it is that the node has failed.

The phi value is calculated using statistical analysis of historical heartbeat arrival times. The algorithm maintains a sliding window of recent inter-arrival times and uses this data to estimate the probability distribution of when the next heartbeat should arrive. If a heartbeat is late, the phi value increases gradually rather than jumping immediately to a failure state.

The phi value represents the confidence level that a node has failed. For example, a phi value of 1 corresponds to approximately 90% confidence, a phi of 2 corresponds to 99% confidence, and a phi of 3 corresponds to 99.9% confidence.

## Gossip Protocols for Heartbeats

As distributed systems grow in size, centralized heartbeat monitoring becomes a bottleneck. A single monitoring node responsible for tracking thousands of servers creates a single point of failure and does not scale well. This is where **gossip protocols** come into play.

Gossip protocols distribute the responsibility of failure detection across all nodes in the cluster. Instead of reporting to a central authority, each node periodically exchanges heartbeat information with a randomly selected subset of peers. Over time, information about the health of every node spreads throughout the entire cluster, much like gossip spreads in a social network.

The basic gossip algorithm: each node maintains a local membership list containing information about all known nodes in the cluster, including their heartbeat counters. Periodically, the node selects one or more random peers and exchanges its entire membership list with them. When receiving a membership list from a peer, the node merges it with its own list, keeping the most recent information for each node.

```python
class GossipNode:  
    def __init__(self, node_id, peers):  
        self.node_id = node_id  
        self.peers = peers  
        self.membership_list = {}  
        self.heartbeat_counter = 0  
        
    def update_heartbeat(self):  
        self.heartbeat_counter += 1  
        self.membership_list[self.node_id] = {  
            'heartbeat': self.heartbeat_counter,  
            'timestamp': time.time()  
        }  
        
    def gossip_round(self):  
        # Update own heartbeat  
        self.update_heartbeat()  
        
        # Select random peers to gossip with  
        num_peers = min(3, len(self.peers))  
        selected_peers = random.sample(self.peers, num_peers)  
        
        # Send membership list to selected peers  
        for peer in selected_peers:  
            self._send_gossip(peer)  
            
    def _send_gossip(self, peer):  
        try:  
            response = requests.post(  
                f"http://{peer}/gossip",  
                json=self.membership_list  
            )  
            received_list = response.json()  
            self._merge_membership_list(received_list)  
        except Exception as e:  
            logging.error(f"Failed to gossip with {peer}: {e}")  
            
    def _merge_membership_list(self, received_list):  
        for node_id, info in received_list.items():  
            if node_id not in self.membership_list:  
                self.membership_list[node_id] = info  
            else:  
                # Keep the entry with the higher heartbeat counter  
                if info['heartbeat'] > self.membership_list[node_id]['heartbeat']:  
                    self.membership_list[node_id] = info  
                    
    def detect_failures(self, timeout_seconds):  
        failed_nodes = []  
        current_time = time.time()  
        
        for node_id, info in self.membership_list.items():  
            if node_id != self.node_id:  
                time_since_update = current_time - info['timestamp']  
                if time_since_update > timeout_seconds:  
                    failed_nodes.append(node_id)  
                    
        return failed_nodes
```

The gossip protocol eliminates single points of failure since every node participates in failure detection. It scales well because the number of messages each node sends remains constant regardless of cluster size. It is also resilient to node failures since information continues to spread as long as some nodes remain connected.

However, gossip protocols also introduce complexity. Because information spreads gradually, there can be a delay before all nodes learn about a failure. This eventual consistency model means that different nodes might temporarily have different views of the cluster state. The protocol also generates more total network traffic since information is duplicated across many gossip exchanges, though this is usually acceptable since gossip messages are small.

Many production systems use gossip-based failure detection. Cassandra, for example, uses a gossip protocol where each node gossips with up to three other nodes every second. Nodes track both heartbeat generation numbers and version numbers to handle various failure scenarios. The protocol also includes mechanisms to handle network partitions and prevent split-brain scenarios.

## Implementation Considerations

One important implementation consideration is the transport protocol.

Should heartbeats use **TCP or UDP**? TCP provides reliable delivery and guarantees that messages arrive in order, but it also introduces overhead and can be slower due to connection establishment and acknowledgment mechanisms.

UDP is faster and more lightweight, but packets can be lost or arrive out of order. Many systems use UDP for heartbeat messages because occasional packet loss is acceptable; the receiver can tolerate missing a few heartbeats without declaring a node dead.

However, TCP is often preferred when heartbeat messages carry critical state information that must not be lost.

Another consideration is **network topology**. In systems spanning multiple data centers, network latency and reliability vary significantly between different paths. A heartbeat between two nodes in the same data center might have a round-trip time of 1 millisecond, while a heartbeat crossing continents might take 100 milliseconds or more. Systems should account for these differences, potentially using different timeout values for local versus remote nodes.

```python
class AdaptiveHeartbeatConfig:  
    def __init__(self):  
        self.configs = {}  
        
    def configure_for_node(self, node_id, location):  
        if location == 'local':  
            config = {  
                'interval': 1000,  # 1 second  
                'timeout': 3000,   # 3 seconds  
                'protocol': 'UDP'  
            }  
        elif location == 'same_datacenter':  
            config = {  
                'interval': 2000,  # 2 seconds  
                'timeout': 6000,   # 6 seconds  
                'protocol': 'UDP'  
            }  
        else:  # remote_datacenter  
            config = {  
                'interval': 5000,  # 5 seconds  
                'timeout': 15000,  # 15 seconds  
                'protocol': 'TCP'  
            }  
            
        self.configs[node_id] = config  
        return config
```

Another important implementation consideration is to ensure that we do not have **blocking operations** in the heartbeat processing path. Heartbeat handlers should execute quickly and defer any expensive operations to separate worker threads.

**Resource management** is also critical. In a system with thousands of nodes, maintaining separate threads or timers for each node can exhaust system resources. We should prefer event-driven architectures or thread pools to efficiently manage concurrent heartbeat processing. Connection pooling would also reduce the overhead of establishing new connections for each heartbeat message.

## Network Partitions and Split-brain

A **network partition** occurs when network connectivity is disrupted, splitting a cluster into two or more isolated groups. Nodes within each partition can communicate with each other but cannot reach nodes in other partitions.

During a partition, nodes on each side will stop receiving heartbeats from nodes on the other side. This creates an ambiguous situation where both sides might believe the other has failed. If not handled carefully, this can lead to **split-brain scenarios** where both sides continue operating independently, potentially leading to data inconsistency or resource conflicts.

Consider a database cluster with three nodes spread across two data centers. If the network connection between data centers fails, the nodes in each data center will form separate partitions. Without proper safeguards, both partitions might elect their own leader, accept writes, and diverge from each other.

To handle network partitions correctly, systems often use **quorum-based approaches**. A quorum is the minimum number of nodes that must agree before taking certain actions. For example, a cluster of five nodes might require a quorum of three nodes to elect a leader or accept writes.

During a partition, only the partition containing at least three nodes can continue operating normally. The minority partition recognizes it has lost quorum and stops accepting writes.

```python
class QuorumBasedFailureHandler:  
    def __init__(self, total_nodes, quorum_size):  
        self.total_nodes = total_nodes  
        self.quorum_size = quorum_size  
        self.reachable_nodes = set()  
        
    def update_reachable_nodes(self, node_list):  
        self.reachable_nodes = set(node_list)  
        
    def has_quorum(self):  
        return len(self.reachable_nodes) >= self.quorum_size  
        
    def can_accept_writes(self):  
        return self.has_quorum()  
        
    def should_step_down_as_leader(self):  
        return not self.has_quorum()
```

## Real-world Applications

Each node in a **Kubernetes** cluster runs a kubelet agent that periodically sends node status updates to the API server. By default, kubelets send updates every 10 seconds. If the API server does not receive an update within 40 seconds, it marks the node as `NotReady`.

Kubernetes also implements **liveness and readiness probes** at the pod level. A liveness probe checks whether a container is running properly, and if the probe fails repeatedly, Kubernetes restarts the container. A readiness probe determines whether a container is ready to accept traffic, and failing readiness probes cause the pod to be removed from service endpoints.

```yaml
apiVersion: v1  
kind: Pod  
metadata:  
  name: example-pod  
spec:  
  containers:  
  - name: app  
    image: myapp:latest  
    livenessProbe:  
      httpGet:  
        path: /healthz  
        port: 8080  
      initialDelaySeconds: 15  
      periodSeconds: 10  
      timeoutSeconds: 2  
      failureThreshold: 3  
    readinessProbe:  
      httpGet:  
        path: /ready  
        port: 8080  
      initialDelaySeconds: 5  
      periodSeconds: 5  
      timeoutSeconds: 2
```

**Cassandra**, a distributed NoSQL database, uses gossip-based heartbeats to maintain cluster membership. Each Cassandra node gossips with up to three other random nodes every second. The gossip messages include heartbeat generation numbers that increment whenever a node restarts and heartbeat version numbers that increment with each gossip round.

Cassandra uses the **phi accrual failure detector** to determine when nodes are down. The default phi threshold is 8, meaning a node is considered down when the algorithm is about 99.9999% confident it has failed. This adaptive approach allows Cassandra to work reliably across diverse network environments.

**etcd**, a distributed key-value store used by Kubernetes, implements heartbeats as part of its Raft consensus protocol. The Raft leader sends heartbeat messages to followers every 100 milliseconds by default. If a follower does not receive a heartbeat within the election timeout (typically 1000 milliseconds), it initiates a new leader election.

---

## Footnotes

Heartbeats are essential to distributed systems. From simple periodic messages to sophisticated adaptive algorithms, heartbeats enable systems to maintain awareness of component health and respond to failures quickly.

The key to effective heartbeat design lies in balancing competing concerns. Fast failure detection requires frequent heartbeats and aggressive timeouts, but this increases network overhead and sensitivity to transient issues. Slow detection reduces resource consumption and false positives but leaves the system vulnerable to longer outages.

As we design distributed systems, consider heartbeat mechanisms early in the architecture process. The choice of heartbeat intervals, timeout values, and failure detection algorithms significantly impacts system behavior under failure conditions.

No matter what we are building, heartbeats remain an essential tool for maintaining reliability.
