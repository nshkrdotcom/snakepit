[Heartbeats in Distributed Systems (arpitbhayani.me)](https://arpitbhayani.me/posts/heartbeats-in-distributed-systems)

> Consider a system with 1000 nodes where each node sends heartbeats to a central monitor every 500 milliseconds. This results in 2000 heartbeat messages per second just for health monitoring. In a busy production environment, this overhead can interfere with actual application traffic.
>
> If your 1000-node busy production environment is run so close to the edge that 2000 heartbeat messages per second, push it into overload, that's impressive resource scheduling.
>
> Really, setting the interval balances speed of detection/cost of slow detection vs cost of reacting to a momentary interruption. If the node actually dies, you'd like to react as soon as possible; but if it's something like a link flap or system pause (GC or otherwise), most applications would prefer to wait and not transition state; some applications like live broadcast are better served by moving very rapidly and 500 ms might be too long.
>
> Re: network partitioning, the author left out the really fun splits. Say you have servers in DC, TX, and CA. If there's a damaged (but not severed) link between TX and CA, there's a good chance that DC can talk to everyone, but TX and CA can't communicate. You can have that inside a datacenter too, maybe each node can only reach 75% of the other nodes, but A can reach B and B can reach C does not indicate A can reach C. Lots of fun times there.
>
> **toast0** 3 hours ago

> > If your 1000-node busy production environment is run so close to the edge that 2000 heartbeat messages per second, push it into overload, that's impressive resource scheduling.
>
> Eeeh I’m not so sure. The overhead of handling a hello-world heartbeat request is negligible, sure, but what about the overhead of having the connections open (file descriptors, maybe >1 per request), client tracking metadata for what are necessarily all different client location identifiers, and so on?
>
> That’s still cheap stuff, but at 2krps there are totally realistic scenarios where a system with decent capacity budgeting could still be adversely affected by heartbeats.
>
> And what if a heartbeat client’s network link is degraded and there’s a super long time between first byte and last? Whether or not that client gets evicted from the cluster, if it’s basically slowloris-ing the server that can cause issues too.
>
> **zbentley** 7 minutes ago

> When systems were smaller I tried to push for the realization that I don’t need a heartbeat from a machine that is currently returning status 200 messages from 60 req/s. The evidence of work is already there, and more meaningful than the status check.
> We end up adding real work to the status checks often enough anyway, to make sure the database is still visible and other services. So inference has a lot of power that a heartbeat does not.
>
> **hinkley** 1 hour ago

> Kingsbury & Bailis's paper on the topic of network partitions: https://github.com/aphyr/partitions-post
>
> **macintux** 3 hours ago

> I've dealt with exactly this. We had a couple thousand webapp server instances that had connections to a MySQL database. Each one only polled its connection for liveliness once per second, but those were little interruptions that were poking at the servers and showed up on top time consuming request charts.
>
> **karmakaze** 2 hours ago

> Related advice based on my days working at Basho: find a way to recognize, and terminate, slow-running (or erratically-behaving) servers.
> A dead server is much better for a distributed system than a misbehaving one. The latter can bring down your entire application.
>
> **macintux** 3 hours ago

> Indeed, which is why I've heard of failover setups where the backup has a means to make very sure that the main system is off before it takes over (often by cutting the power).
>
> **rcxdude** 2 hours ago

> Usually we call this STONITH
>
> **xyzzy_plugh** 11 minutes ago

> I did this systematically: at the first sign of outlier in performance one system would move itself to another platform and shut itself down. The shutdown meant turn all services off and let someone log in to investigate and rearrange it again. This system allowed different roles to be assigned to different platform. The platform was bare metal or bhyve vm. It worked perfect.
>
> **owl_vision** 2 hours ago

> Docker and Kubernetes have health check mechanisms to help solve for this;
> Docker docs > Dockerfile HEALTHCHECK instruction: https://docs.docker.com/reference/dockerfile/#healthcheck
>
> Podman docs > podman-healthcheck-run, docker-healthcheck-run: https://docs.podman.io/en/v5.4.0/markdown/podman-healthcheck...
>
> Kubernetes docs > "Configure Liveness, Readiness and Startup Probes" https://kubernetes.io/docs/tasks/configure-pod-container/con...
>
> **westurner** 1 hour ago

> I've been noodling a lot on how IP/ARP works as a "distributed system". Are there any reference distributed systems that have a similar setup of "optimistic"/best effort delivery? IPv6 and NDP seem like they could scale a lot, what would be the negatives about using a similar design for RPC?
>
> **candiddevmike** 1 hour ago

> Does anyone have recommendations on books/papers/articles which cover gossip protocols?
> I have been more interested in learning about gossip protocols and how they are used, different tradeoffs, etc.
>
> **__turbobrew__** 3 hours ago

> While not a book/paper/article, this is good implementation practice: https://fly.io/dist-sys/
>
> **John23832** 21 minutes ago

> Two interesting papers:
> * Epidemic broadcast trees: https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf
>
> * HyParView: https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf
>
> The iroh-gossip implementation is based on those: https://docs.rs/iroh-gossip/latest/iroh_gossip/
>
> **the_duke** 1 hour ago

> Thank you
>
> **__turbobrew__** 1 hour ago

> https://thesecretlivesofdata.com/raft/
>
> **rishabhaiover** 3 hours ago

> > https://thesecretlivesofdata.com/raft/
> Are you suggesting to use raft as a gossip protocol? Run a replicated state machine with leader election, replicated logs and stable storage?
>
> **rdtsc** 2 hours ago

> Raft is a consensus protocol, which is very different from a gossip protocol.
>
> **the_duke** 1 hour ago

> I'm sorry, I got confused.
>
> **rishabhaiover** 1 hour ago

> > When a system uses very short intervals, such as sending heartbeats every 500 milliseconds
> 500 milliseconds is a very long interval, on a CPU timescale. Funny how we all tend to judge intervals based on human timescales
>
> Of course the best way to choose heartbeat intervals is based on metrics like transaction failure rate or latency
>
> **paulsutter** 4 hours ago

> Top shelf would be noticing an anomaly in behavior for a node and then interrogating it to see what’s wrong.
> Automatic load balancing always gets weird, because it can end up sending more traffic to the sick server instead of less, because the results come back faster. So you have to be careful with status codes.
>
> **hinkley** 1 hour ago

> Well, it is called a heartbeat after all, not a oscillator beat :-)
>
> **blipvert** 2 hours ago

> Why can't network time synchronization services like SPTP and WhiteRabbit also solve for heartbeats in distributed systems?
>
> **westurner** 1 hour ago

> Some fuzzy thinking in here. "A heartbeat sent from a node in California to a monitor in Virginia might take 80 milliseconds under normal conditions, but could spike to 200 milliseconds during periods of congestion." This is not really the effect of congestion, or at best this sentence misleads the reader. The mechanism that causes high latency during congestion is dropped frames, which are retried at the protocol level based on timers. You can get a 200ms delay between two nodes even if they are adjacent, because the TCP minimum RTO is 200ms.
>
> **jeffbee** 1 hour ago
