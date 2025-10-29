# Native‑First Control Plane Migration

**Date:** 2025-10-28  
**Author:** Platform Architecture  
**Status:** Draft – Ready for review  

---

## Purpose

Define the migration path from the current AWS-centric implementation of the Nordic Road intelligence pipeline to a **native-first** architecture that runs on customer-controlled infrastructure (single server, air-gapped, or hybrid on-prem) while retaining AWS support as an optional deployment target.

## Goals

1. Deliver the three-legged stool (automated aggregation, predictive analysis, hyper-local insight) on a **self-contained stack**: Postgres/pgvector storage, Dagster orchestration, containerised Python services, LiveView UI.
2. Preserve configurability so the same codebase can target **AWS managed services** when required.
3. Provide an incremental migration plan that keeps the current customer commitments (AWS demo in four weeks) on track while setting up the native-first build as the primary evolution path.

## Guiding Principles

- **Hexagonal all the way down.** RuntimeServices, ports, and adapters are the seam that lets us toggle back-ends. Do not regress to SDK imports in services.
- **Feature parity by slices.** Deliver a narrow but complete workflow end-to-end before expanding scope (ingest → validate → report).
- **Config-first deployments.** Every deployment choice (AWS vs on-prem) must be driven by configuration (env vars, YAML, or CLI flags) instead of code branches.
- **Deterministic tests.** Keep the mock/local test harness working so we can exercise both stacks without external dependencies.
- **Document as code.** Each migration phase must ship with updated runbooks, diagrams, and CLI scripts.

---

## Current Baseline

| Layer | Today | Limits |
| --- | --- | --- |
| Storage | DynamoDB + S3 (+ pgvector/MGRS in experiments) | AWS data models baked into fixtures; no Postgres adapters |
| Orchestration | Step Functions → Lambdas/ECS | No native orchestrator; events hard-coded to SFN JSON |
| Runtime services | Python hexagonal refactor in progress | AWS adapters only; RuntimeServices exists but few alternate impls |
| UI | Phoenix LiveView (legacy) | Depends on AWS-backed API output |
| ML/LLM | Anthropic/OpenAI (env-driven) | No local model adapters |
| Testing | In-memory AWS, runtime fakes, LocalStack | Fakes mimic AWS semantics; no Postgres/Dagster test doubles |

---

## Target Architecture (Native-First)

```
┌──────────────────────────────────────────────────────────┐
│   User Interface: Phoenix LiveView / CLI / REST           │
└───────────────▲───────────────────────────────────────────┘
                │
┌───────────────┴───────────────────────────────────────────┐
│   Orchestration Layer: Dagster (self-hosted)               │
│   • Assets & jobs call Python services via RuntimeServices │
│   • Schedules + backfills replace Step Functions/Lambda    │
└───────────────▲───────────────────────────────────────────┘
                │
┌───────────────┴───────────────────────────────────────────┐
│   Service Layer (Python hexagonal modules)                 │
│   • Ports for storage, ML, external APIs                   │
│   • Adapters for Postgres, pgvector, local LLMs            │
└───────────────▲───────────────────────────────────────────┘
                │
┌───────────────┴───────────────────────────────────────────┐
│   Data Plane:                                              │
│   • Postgres 16 + PostGIS + Timescale + pgvector           │
│   • MinIO (object store)                                   │
│   • Redis / RabbitMQ (optional for queues)                 │
└───────────────▲───────────────────────────────────────────┘
                │
┌───────────────┴───────────────────────────────────────────┐
│   ML/LLM Infrastructure                                    │
│   • vLLM / Text Generation Inference inside container      │
│   • llama.cpp for edge devices                             │
│   • Optional Anthropic/OpenAI adapters via config          │
└───────────────────────────────────────────────────────────┘
```

| Capability | Native-first | AWS equivalent |
| --- | --- | --- |
| State store | Postgres schemas | DynamoDB tables |
| Vector search | pgvector extension | Pinecone or OpenSearch |
| Object storage | MinIO | S3 |
| Orchestration | Dagster | Step Functions |
| Execution | Containerised services (Systemd/K8s) | Lambda/ECS |
| Pipelines | Dagster assets/jobs | Step Functions state machines |
| Telemetry | Prometheus/Grafana, AITrace | CloudWatch, X-Ray |

---

## Migration Phases

### Phase 0 – Finish Hexagonal Python Refactor (In Flight)
- ✅ Finalise RuntimeServices, logging, fixtures, and testing harness.
- ✅ Freeze AWS behavior as “current mode”.
- ⏳ Enter baseline tests in CI (run-all.sh, run-tests.sh).

### Phase 1 – Native Storage Adapters (Week 1–2 after stool demo)
1. **Design Postgres schemas** mirroring Dynamo tables (region configs, articles, claims, reports, prompts). Include migration scripts and fake data seeds.
2. **Implement storage ports:**
   - `DynamoDBService` → `PostgresRepository` using SQLAlchemy or psycopg (choose one).
   - S3 interactions → `ObjectStoreService` backed by MinIO (use boto-compatible library or pathlib).
3. **Update fixtures** to support both Dynamo (JSON) and Postgres (SQL/CSV). Add toggle in `conftest.py`.
4. **Introduce configuration switch** (`STORAGE_BACKEND=aws|postgres`).
5. **Add tests** that run service logic against Postgres in Docker Compose (use ephemeral DB for CI).

Deliverable: same ingest/report slice writes to Postgres when `STORAGE_BACKEND=postgres` and to Dynamo otherwise.

### Phase 2 – Orchestration Layer Swap (Week 3–4 after stool demo)
1. **Model workflows as Dagster jobs/assets**: ingestion, enrichment, report generation.
2. **Wrap Step Functions events** as Dagster op configs so existing handlers can run under Dagster.
3. **Create Dagster deployment** (Docker Compose with dagit + daemon).
4. **Provide CLI parity** (`./dagster.sh run ingestion`, etc.).
5. **Keep Step Functions definitions** for AWS mode; produce translation layer from Dagster runs to Step Functions for cloud deployment.

Deliverable: pipeline runs via Dagster locally; Step Functions remains an optional deployment target.

### Phase 3 – ML/LLM Flexibility (Week 5–6 after stool demo)
1. **Abstract LLM/embedding ports** further: define provider registry + config schema (YAML).
2. **Implement local adapters**:
   - vLLM server container for generation.
   - Sentence-transformers or local embedding model for vectors.
3. **Reuse existing Anthropic/OpenAI adapters** as remote options.
4. **Update tests** to cover deterministic local model stubs.
5. **Expose config** via environment or `config/llm.yml`.

Deliverable: predictive + summarisation modules run either on local models or SaaS APIs based on configuration.

### Phase 4 – Deployment Profiles (Week 7–8 after stool demo)
1. **Create deployment manifests**:
   - On-prem single host: Docker Compose (Postgres, Dagster, Python services, LiveView UI, MinIO, vLLM).
   - Air-gapped: same plus manual model weights packaging.
   - AWS hybrid: reuse existing Terraform modules but point to new ports as needed.
2. **Document provisioning**: security hardening, TLS, backups.
3. **Integrate AITrace/telemetry** for both environments.

Deliverable: `deploy/native/` and `deploy/aws/` directories with scripts and configs; runbooks in `docs/`.

### Phase 5 – Testing & Certification (Ongoing)
1. Expand test harness to run both AWS and native modes in CI.
2. Add contract tests ensuring parity between storage backends.
3. Provide CMMC / FedRAMP evidence templates as part of documentation.

---

## Workstreams & Parallelism

| Workstream | Owner | Depends On | Output |
| --- | --- | --- | --- |
| Postgres adapter | Platform | Phase 0 | Storage port implementation |
| Vector store | Platform | Postgres adapter | pgvector schema, similarity search |
| Dagster integration | Platform | Phase 1 | Dagster jobs + CLI |
| LLM adapters | AI/ML | Phase 0 | Local inference servers |
| Deploy tooling | DevOps | Phases 1–3 | Docker Compose, Terraform updates |
| UI alignment | Frontend | Phase 1 | LiveView reads native API |

---

## Configuration Matrix

| Component | Native (default) | AWS option | Config key |
| --- | --- | --- | --- |
| Storage | Postgres (psycopg) | DynamoDB | `STORAGE_BACKEND=postgres|aws` |
| Object store | MinIO | S3 | `OBJECT_STORE_BACKEND=minio|s3` |
| Vector search | pgvector | Pinecone/OpenSearch | `VECTOR_BACKEND=pgvector|pinecone` |
| Orchestration | Dagster | Step Functions | `ORCHESTRATION_BACKEND=dagster|step-functions` |
| Execution | Systemd/K8s | Lambda/ECS | Deployment profile |
| LLM provider | vLLM/sentence-transformers | Anthropic/OpenAI | `LLM_PROVIDER=local|anthropic|openai` |

Implementation tip: centralise config in `shared/app_config.py` with a dataclass that validates combinations and exposes helper methods (e.g., `config.create_storage_repo()`).

---

## Testing Strategy

1. **Unit Tests** continue to use runtime fakes (AWS-style). Add Postgres fixtures (SQL scripts) and local LLM stubs.
2. **Integration suites**:
   - `pytest -m native` spins up Postgres/Dagster containers.
   - `pytest -m aws` runs against LocalStack (existing).
3. **Contract tests** verifying identical outputs for given inputs across backends.
4. **CI matrix**: GitHub Actions job for `native` and `aws` flavours.

---

## Deliverables Checklist

- [ ] Postgres + pgvector schema diagrams and migration scripts.
- [ ] Storage adapters (`PostgresRepository`, `MinIOObjectStore`).
- [ ] Dagster repository with jobs/assets/definitions.
- [ ] Configurable RuntimeServices factory.
- [ ] Local LLM/embedding adapters with packaging instructions.
- [ ] Deployment manifests for native, hybrid, AWS.
- [ ] Updated documentation (developer guide, ops runbooks, compliance notes).
- [ ] Updated test harness supporting both execution modes.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Dual-path drift | Native and AWS behaviours diverge | Contract tests + shared domain logic |
| Increased ops complexity | More services to run on-prem | Docker Compose defaults, one-command startup |
| Model performance variance | Local models differ from SaaS | Provide evaluation tooling + fallback to SaaS |
| Timeline pressure | Feature work (three-legged stool) competes with migration | Ship stool on AWS first, start migration immediately after demo |

---

## Next Actions (Post demo)

1. Finalise stool on AWS (current deadline).
2. Kick off Phase 1 immediately after deliverable acceptance:
   - Schedule design session on Postgres schema.
   - Update backlog with adapter tasks.
3. Align exec stakeholders on rollout sequencing (native-first becomes primary roadmap).
4. Update this document as phases complete (move to “In Progress” then “Done”).

---

**Document control:** keep changes under versioned directories (`docs/20251028/native_first_migration/`). Update status and add additional files (e.g., schema diagrams, playbooks) as each phase starts.

