# Current State

* Single repo containing a React frontend, a Python backend, and deployment bash scripts.
* Runs on EC2 VMs on AWS, with a PostgreSQL RDS database and S3 object storage.
* Deployment is manual, via SSH.
* No CI/CD, no IaC, no centralized logging, and minimal monitoring (AWS dashboards only).
* Load spikes occur when large clients run expensive tasks, causing slowdowns and occasional downtime due to:
  * High memory usage in the application, leading to swap thrashing.
  * High database load when writing hundreds of thousands of rows.

# Proposal

## Compute: Migrate to ECS (Fargate)

Migrating off EC2 VMs to **ECS on Fargate**, managed via Terraform, rather than Kubernetes (self-managed or EKS).

**Why not Kubernetes:**

Today's system is two services, a React frontend and a Python backend. Standing up a Kubernetes cluster to run two services isn't justified by the workload; it brings meaningful complexity and cost that isn't offset by any real benefit at this scale. Even EKS (AWS-managed control plane) doesn't remove this overhead, the add-ons required just to make the cluster usable in production still need to be deployed and maintained:

* An ingress/load balancer controller (e.g. AWS Load Balancer Controller) to expose services.
* CoreDNS and CNI networking.
* A node autoscaler (e.g. Karpenter, or the more limited Cluster Autoscaler) to scale EC2 capacity, unless also paying the added per-pod cost of Fargate on EKS.
* A GitOps/deploy controller (e.g. Argo CD) so deploys aren't manual.

That's a non-trivial platform to build and operate for two services, on top of the EKS control plane cost itself.

**Why ECS on Fargate:**

* No cluster or node layer to manage, Fargate runs containers directly, so there's no EC2 fleet to patch, size, or scale at the node level.
* Native, built-in service autoscaling (target-tracking on CPU/memory/request count), no extra autoscaler component needed.
* Deploys, task definitions, and scaling policies are all managed as plain Terraform resources, keeping infra and app deploys in one consistent IaC workflow.
* Meaningfully cheaper and simpler to operate than EKS at this scale, while still providing autoscaling, rolling deploys, and AWS-native integration (ALB, IAM roles per task, CloudWatch).

**When to revisit:** if the system grows into many more independently-deployed services, or needs capabilities Kubernetes offers natively (e.g. complex multi-service traffic policies, a large platform team to operate it), EKS becomes worth reconsidering. For a two-service app today, ECS/Fargate accomplishes everything required at a fraction of the  cost (operational and actual).

## Backend: Task Dispatcher

**Problem:** large clients' expensive tasks run inside the same backend serving normal traffic. Task memory usage appears to scale with the size of the task/client, so a heavy task can consume enough memory to cause swap thrashing and degrade the service for everyone else.

**Assumption:** exact internals of these tasks aren't known, but the workload appears to be expensive, variably-sized jobs (memory need roughly correlated to client size) rather than uniform request traffic this shapes the proposal below.

**Proposal:** replace the single always-on backend with a lightweight API dispatcher. The dispatcher accepts a task request and enqueues it onto a queue (SQS); a small poller drains the queue and launches each job as its own isolated ECS Fargate task, sized to what that job needs.

**Why per-task isolation instead of a single scaled backend:**

* One client's heavy job can't degrade another's — each runs with its own dedicated CPU/memory allocation, which is what actually fixes the swap-thrashing problem, rather than just giving the shared backend more headroom.
* A single service scaled to survive worst-case bursts is expensive to run and awkward to load-balance, since normal traffic and occasional heavy jobs have very different resource profiles. Dispatching each job as its own task means only paying for the heavy compute when a heavy job is actually running.

**Why a queue in front of dispatch:** launching an ECS task directly from the API request would tie task startup to the request path and hit ECS `RunTask` API throttling limits under a burst of simultaneous submissions. A simple SQS queue decouples "client submits a task" from "a task gets launched" — the API just enqueues and returns immediately, and the poller drains at a controlled rate, smoothing bursts and giving room to retry if a `RunTask` call is throttled.

**Why ECS over Lambda:** Lambda was considered as a dispatch target, but the workload's characteristics — large data writes and potentially long-running processing — run into Lambda's hard limits (15-minute max execution, limited ephemeral storage). ECS Fargate tasks don't have those constraints, so ECS is the better fit here.

**Known trade-off:** launching a fresh Fargate task per job adds on the order of tens of seconds of startup latency before work begins. Given from what the doc says or seems to suggest these are already expensive, longer-running jobs, that overhead is likely negligible relative to total task duration, so not consider a problem to solve here given this assumption -> actual task duration isn't confirmed by anything in the current description.

## Database

Postgres (like relational databases generally) doesn't scale writes horizontally — there's a single writer. That constraint shapes the approach below, roughly in priority order:

1. **Batch writes, not row-by-row.** The current pattern appears to write row-by-row; switching to batch/bulk writes (multi-row `INSERT`, or `COPY` for large loads) is an application-level change and the highest-leverage fix, since it directly reduces the load each task puts on the database.
2. **Vertical scaling** of the RDS Postgres instance as additional write headroom is needed. This has a ceiling (still a single writer), but is a simple lever before reaching for anything more complex.
3. **RDS Proxy in front of the database.** Since tasks now run as independent ECS tasks dispatched concurrently, and Postgres can't handle unbounded concurrent connections, a proxy pools and manages those connections so a burst of concurrently-dispatched tasks doesn't exhaust the database's connection limit.
4. **Read replicas** are available for horizontal read scaling, but nothing in the current description points to read load being the bottleneck — lower priority than the above.

## External Partner Connectivity (Fixed Outbound IP)

**Problem:** the system needs to connect to external partner systems (databases, APIs) that require IP whitelisting, outbound traffic must originate from a predictable, fixed IP address.

**Assumption:** the existing VPC already has public/private subnets and route tables in place, not something this proposal needs to design from scratch, but it's not specified whether a NAT Gateway already exists. This covers both cases: add one if missing, reuse it if already present.

**Proposal:** a NAT Gateway, which lets resources in private subnets reach the internet for outbound traffic, and is allocated a static Elastic IP (EIP) by default. That EIP is the fixed address handed to partners for whitelisting, with private route table entries directing outbound traffic through it.

AWS recommends one NAT Gateway per AZ for high availability, but depending on cost tolerance we can start with a single one or multiple. Given our scale, starting with one NAT Gateway and adding more as the system grows is fine, the difference is just sharing each NAT's IP with the partner to whitelist. Starting with one is feasible, easy enough to add more as needed.

## Observability

**Proposal:** start with CloudWatch, native to ECS/AWS, minimal setup — and layer on OpenTelemetry-based tooling once business-analytics and deeper troubleshooting needs grow.

**CloudWatch (starting point):**

* Container Insights gives CPU/memory/network per ECS task and service.
* Logs, via the `awslogs` driver, capture stdout/stderr from every task, errors are visible as log content, and metric filters can turn recurring error patterns into countable metrics/alarms.
* The ALB gives request-level latency and error-rate metrics natively.
* Not automatic: application-level tracing (which task/endpoint is slow, and why) and error aggregation/triage beyond raw logs, those need custom instrumentation.
* Good enough for day-to-day developer troubleshooting at this stage, logs and default metrics, queryable directly in the AWS console, and easy enough to search/summarize with AI tooling (e.g. Claude Code) instead of digging through the console by hand.

**Alerting:** CloudWatch Alarms on a small set of key signals, ECS CPU/memory, SQS queue depth (dispatcher backlog), RDS CPU/connections, ALB 5xx rate, enough to catch the failure modes this proposal is built around (memory pressure, DB overload, backlog buildup), without a full SLO program yet.

**Business analytics + deeper observability:** CloudWatch alone doesn't give custom business metrics (e.g. tasks processed per client) or distributed tracing (following one client task across dispatcher → ECS task → DB). OpenTelemetry instrumentation is the proposed path for both, one SDK captures custom metrics and traces, instead of separate tooling for each. Where that data gets sent is a separate decision:

* **Datadog** least setup effort, well-established, but cost scales quickly with usage.
* **Self-hosted Prometheus/VictoriaMetrics + Grafana** cheaper at scale, but it's another service to run and maintain (can run on ECS like everything else, generally a straightforward install, but still ongoing ops burden).
* **CloudWatch's native OTel support** newest option, keeps everything in one place, but untested here and not yet proven enough to fully commit to. I'm also not familiar with it so hard to recommend would need a POC.

**Recommendation:** start with CloudWatch defaults, covers day-to-day troubleshooting immediately, no extra cost or setup. Add OTel instrumentation once business metrics/tracing are actually needed, sending data to Datadog or self-hosted Prometheus/Grafana depending on budget and engineering bandwidth at the time. Revisit CloudWatch's native OTel support once it matures.

**Scope note:** this covers dashboard-style business metrics (e.g. tasks processed, volume per client) alongside technical metrics, not BI-style reporting (customer-facing trends, revenue breakdowns). That would require a different kind of tool, i'm assuming its not in the scope of this task, and leaving out the specific details on that for now, as designing that would be fairly heavy left and woudl prob require its own seperate design doc 

## CI/CD

**Proposal:** GitHub Actions, via a single workflow (`.github/workflows/build-and-deploy.yaml`) triggered on pull requests and on pushes to `main`.

**Why GitHub Actions:** at this scale (small team, handful of services), the free tier is very likely sufficient, and since the code already lives on GitHub, it requires no new platform or integration to adopt. The community action ecosystem is extensive enough that most pipeline stages below can be built from existing, well-maintained actions rather than custom scripting.

**On pull request:**

* Run unit tests.
* Build the image (verifies it builds cleanly).
* The image is not pushed — a PR only needs to prove the change is buildable and passes tests, not produce a deployable artifact.

**On merge to `main`:**

* Tests are not re-run — `main` only accepts changes via PR, and those already passed CI. *(Known trade-off: this skips catching the case where two independently-passing PRs combine badly once merged. Acceptable at today's team size/merge frequency; worth revisiting if either grows.)*
* Build and push the image, tagged with the commit SHA so every push maps to a traceable, immutable image.
* GitHub Packages (GHCR) is used as the registry — no separate registry to stand up or pay for at this scale.
* A deploy step updates the long-running ECS services (frontend/API) to the new image and waits for the deployment to report healthy before considering it done.
* Dispatcher-launched tasks (see Backend: Task Dispatcher) aren't long-running services, so there's nothing to "update" directly — the deploy step refreshes the task definition they launch from, so the next dispatched task picks up the new image.

**Rollback:** ECS's built-in deployment circuit breaker automatically rolls a service back to its previous stable task definition if a new deployment fails to reach a healthy state — no separate rollback tooling needed.

Full implementation lives in the repo — see `.github/workflows/build-and-deploy.yaml`.

### Environments

The flow above is described against a single environment. In practice, at least a dev and prod environment are needed, possibly a third (e.g. staging) as the system matures.

**Option considered: branch-per-environment.** Long-lived branches per environment, e.g. `dev` and `main` (= prod). A PR merges into `dev`, which triggers the pipeline against the dev environment; promoting to prod means merging `dev` into `main`. This is a proven pattern plenty of teams run successfully, but only with good branch hygiene — keeping multiple long-lived branches in sync is ongoing maintenance, and drift between them is a common failure mode.

**Recommendation: single `main` branch, manual gate for prod.** Keep the flow already described — merge to `main` builds, pushes, and auto-deploys to dev. Promoting to prod is a separate, manually-triggered step (e.g. a `workflow_dispatch` workflow) that deploys a specific, already-built image (identified by its commit SHA tag) to prod once it's been validated in dev. No second long-lived branch to maintain, and promotion becomes an explicit, auditable action instead of a branch merge.

**Trade-off:** branch-per-environment gives an implicit rollback point — the previous environment branch's state. A single-branch approach loses that, but rollback is still straightforward: every pushed image is tagged with its commit SHA, so rolling back means redeploying a previous known-good tag. For added control, tags can be tied to a release/version scheme (e.g. a tag cut at merge or promotion time) rather than relying solely on commit SHAs, giving an explicit, human-readable version to roll back to.

## Deferred / Future Considerations

Considered but intentionally left out of this proposal, not needed to meet the requirements as understood/assumed today, worth revisiting if that changes:

* **Sharding.** A valid path if write volume eventually outgrows batching + vertical scaling + connection pooling, but adds significant complexity that isn't warranted based on what's known today.
* **Step Functions (or similar) for task orchestration/recovery.** The queue in front of the dispatcher smooths bursty submission, it doesn't recover a task that fails partway through execution. Step Functions would add that, but is an independent concern from the queue and and since not stated assuming not part of today's requirements. A lighter interim step: extend the queue with a dead-letter queue (DLQ) so a task that fails or times out during *dispatch* gets retried automatically and, after repeated failures, routed to the DLQ instead of silently dropped — this only covers dispatch-level failures, not recovery from a task that fails mid-execution, which is the harder problem Step Functions would actually solve.

