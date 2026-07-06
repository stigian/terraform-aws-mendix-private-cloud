# Design Document

Private Mendix Platform (PMP) on AWS: Modernization & Air-Gapped Delivery

## Overview

This design modernizes the `terraform-aws-mendix-private-cloud` module (branch `feat/pmp-modernization`, forked from `dev/pmp`) and layers the Private Mendix Platform on top of it, targeting two connectivity profiles (`connected` / `airgapped`) across the commercial (`aws`) and GovCloud (`aws-us-gov`) partitions only. It realizes the twelve requirements in `requirements.md`.

The guiding principle is a **layered architecture with a single connectivity-profile abstraction** that every layer keys off of:

```
Layer 4  App lifecycle      Mendix app: create → commit (GitLab) → build (MDA) → deploy
Layer 3  Platform (PMP)     PCLM, portal, build tooling            [helmfile, pipeline-driven]
Layer 2  Foundation (Mx4PC) Mendix Operator + plans (db/storage)   [Terraform: helm_release]
Layer 1  Substrate          VPC, EKS, RDS, S3, ECR, KMS, IAM, SSO  [Terraform]
Layer 0  Supply chain       Vendored images/charts/binaries        [prestaged in ECR/S3]
```

Terraform owns Layers 0–2. The PMP install layer (Layer 3) and app lifecycle (Layer 4) run through the in-cluster GitLab CI/CD pipeline. All layers consume artifacts from the Layer 0 supply chain, whose sourcing behavior changes with the connectivity profile.

### Version baseline (pinned in this design)

| Component | Current (`dev/pmp`) | Target |
|---|---|---|
| `terraform-aws-modules/eks/aws` | v19.21.0 (commit pin) | v21.x (registry) |
| `hashicorp/aws` provider | >= 5.83 | >= 5.83, tested on 6.x |
| Kubernetes / EKS | 1.31 (var default 1.33) | current supported (default 1.33+) |
| Compute | fixed 3-node managed group, Bottlerocket FIPS | EKS Auto Mode (POC-gated; managed-node contingency only if POC fails) |
| Cluster auth | `aws-auth` ConfigMap | EKS access entries |
| Mendix Operator | 2.20.1 | >= 2.21.0 (PCLM prerequisite; no hard Gateway-API dependency) |
| Ingress | NGINX (disabled on `dev/pmp`) | classic Ingress via ALB (internal scheme); NGINX removed |
| PostgreSQL | 14.15 | 17.x |

> **PostgreSQL major note.** The PG major is driven by the pinned GitLab chart: GitLab Helm chart 10.x / GitLab 19.x requires PostgreSQL 17 minimum (chart 10.0 removed PG16 support), which is the binding constraint. PostgreSQL 17 is within the Mendix operator's supported range (13–17), RDS supports 17, and PCLM's documented floor is 12 (no known ceiling). The only residual is a low-risk confirmation checkbox that PCLM runs on 17 — not a compatibility risk.

### Requirement-to-section traceability

| Requirement | Design section |
|---|---|
| 1 Connectivity profiles / operator mode / partitions | §2 Profile model, §3.1 |
| 2 VPC / networking | §3.2 |
| 3 EKS modernization (incl. FIPS on Auto Mode) | §3.3, §4 Auto Mode POC, §5 |
| 4 SSO / OIDC | §3.6 |
| 5 Dependency vendoring | §3.5 |
| 6 Secrets (PMP-native IRSA read from Secrets Manager) | §3.7 |
| 7 PMP install layer | §3.8 |
| 8 App lifecycle | §3.9 |
| 9 Observability | §3.10 |
| 10 CI/CD (GitLab) | §3.11 |
| 11 Backward compatibility / migration | §5 |
| 12 Documentation | §6 |

## Non-Goals

- Building the Mendix application model (Studio Pro work).

- Multi-region / multi-account landing zone.
- Production-grade HA tuning beyond cert/demo needs.
- Optional PMP components not required by the certification — Svix (webhooks), Maia (LLM assistant), PDF DocGen, and Marketplace — are out of scope; only PCLM plus the portal and build tooling are installed.

## Architecture

The architecture is the layered model in the Overview combined with the connectivity-profile and operator-mode abstraction below. Layers 0–2 are Terraform-owned; Layers 3–4 run through the GitLab pipeline. Every layer's behavior is parameterized by the two orthogonal inputs defined here.

### 2. The connectivity-profile and operator-mode model

Two orthogonal input variables drive conditional behavior across the module. Keeping them separate (rather than conflating network state with operator registration) is the central design decision that satisfies Requirement 1. `connectivity_profile` has two values — `connected` and `airgapped` — because air-gapped is a single state regardless of partition: the cluster always reaches its own partition's control plane via VPC endpoints, and "no internet egress" is the invariant. How ECR/S3 get populated (pull-through cache vs out-of-band staging) is a staging-time operational detail, not a separate profile.

### 2.1 Variables

```hcl
variable "connectivity_profile" {
  type        = string
  default     = "connected"
  description = "Network state: connected (internet egress allowed) | airgapped (no egress, partition endpoints only)"
  validation {
    condition     = contains(["connected", "airgapped"], var.connectivity_profile)
    error_message = "connectivity_profile must be one of: connected, airgapped."
  }
}

variable "operator_mode" {
  type        = string
  default     = "standalone"
  description = "Mendix operator registration: connected (portal) | standalone (no portal)"
  validation {
    condition     = contains(["connected", "standalone"], var.operator_mode)
    error_message = "operator_mode must be one of: connected, standalone."
  }
}
```

### 2.2 Derived locals and cross-variable constraints

```hcl
locals {
  # Network behavior derived from the profile
  allow_internet_egress = var.connectivity_profile == "connected"
  create_nat_gateway    = var.connectivity_profile == "connected" && var.create_vpc
  private_only_endpoint = var.connectivity_profile == "airgapped"
  need_vpc_endpoints    = var.connectivity_profile == "airgapped"

  # Partition awareness (never hardcode "aws")
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
}
```

The `airgapped` → `standalone` constraint (Requirement 1.7) is enforced with a `check` block in the root module (variable `validation` cannot cross-reference another variable):

```hcl
check "operator_mode_consistency" {
  assert {
    condition = !(var.connectivity_profile == "airgapped" && var.operator_mode == "connected")
    error_message = "operator_mode='connected' requires connectivity_profile='connected' (the Mendix portal is unreachable when air-gapped)."
  }
}
```

### 2.3 Profile behavior matrix

| Concern | connected | airgapped |
|---|---|---|
| NAT/IGW | Allowed | No |
| EKS public endpoint | Allowed | Disabled |
| VPC interface endpoints | Optional | Required |
| Artifact source | Upstream OK | In-partition ECR/S3 (pull-through where egress exists, else pre-staged) |
| Operator mode | connected or standalone | standalone (forced) |
| SSO IdP | external OIDC/SAML (GitLab OIDC for the demo) | external OIDC/SAML (in-cluster, e.g. GitLab) |
| Internet verification step | n/a | required |

### 2.4 Partition neutrality

All ARNs and endpoints derive from `data.aws_partition.current` and `data.aws_region.current`. AMI owner IDs, IAM policy ARNs (e.g., managed policies), and service principals use `local.partition` / `local.dns_suffix`. Feature availability is gated by input flags with documented defaults, so a partition lacking a feature selects the partition-appropriate alternative rather than failing (Requirement 1.8, 1.9). The target partition set is {`aws`, `aws-us-gov`}; GovCloud requires `aws-us-gov` ARNs, service endpoints, and DNS suffixes to be derived dynamically rather than hardcoded. Air-gapped deployments are structurally identical across commercial and GovCloud — the partition only changes endpoint/ARN derivation, not the module's structure.

## Components and Interfaces

### 3. Component design

### 3.1 Module structure

The root module orchestrates submodules. New submodules are added for networking, identity, GitLab, and vendoring; existing submodules (databases, file-storage, container-registry, monitoring) are retained and adjusted.

```
terraform-aws-mendix-private-cloud/
├── main.tf                     # orchestration, profile locals, checks
├── variables.tf                # + connectivity_profile, operator_mode, create_vpc, artifact source vars
├── outputs.tf
├── modules/
│   ├── vpc/                    # extended: conditional create, endpoints, no-NAT profiles
│   ├── databases/              # retained (RDS PostgreSQL); reused by GitLab
│   ├── file-storage/           # retained (S3); reused by GitLab + MDA storage
│   ├── container-registry/     # extended: pull-through cache + mirrored repos
│   ├── monitoring/             # adjusted: AMP (managed Prometheus) + Grafana + Loki, reached via VPC endpoints when airgapped
│   ├── identity/               # NEW: pluggable OIDC/SAML wiring (no IdP provisioned) + access entries
│   ├── gitlab/                 # NEW: GitLab CNH Helm + Runner, reusing RDS/S3
│   └── vendoring/              # NEW: ECR repos, pull-through rules, S3 artifact buckets
├── charts/mendix-installer/    # retained: operator bootstrap (now parameterized by operator_mode)
├── helmfile/                   # NEW: PMP install layer (helmfile.yaml + values)
├── pipelines/                  # NEW: GitLab CI definitions (.gitlab-ci.yml, stages)
└── vendor/ (or manifest)       # NEW: prestaging manifest / helper (mechanism TBD, §3.5)
```

### 3.2 VPC / networking (Requirement 2)

The existing `modules/vpc` (a `terraform-aws-modules/vpc/aws` wrapper) is extended rather than replaced.

Design points:
- **`create_vpc` toggle**: root passes either the created VPC outputs or the `vpc_id`/`vpc_private_subnets` inputs to downstream modules via a single `local.vpc_id` / `local.private_subnets` indirection, so EKS, RDS, and endpoints reference one source. A `check` block rejects conflicting inputs (`create_vpc=true` plus a non-empty `vpc_id`).
- **Profile-driven networking**: NAT/IGW only when `local.create_nat_gateway`. For `airgapped`, `enable_nat_gateway=false` and interface endpoints are created.
- **VPC endpoints** (interface unless noted) created when `local.need_vpc_endpoints`: `ecr.api`, `ecr.dkr`, `s3` (gateway), `ec2`, `sts`, `logs`, `elasticloadbalancing`, `ssm`, `ssmmessages`, `ec2messages`, `aps` and `aps-workspaces` (AWS Managed Service for Prometheus), plus those Auto Mode requires (`eks`, `eks-auth` for Pod Identity). Endpoint set is a parameterized list with these defaults so partitions can adjust.
- **Subnet tags**: `kubernetes.io/role/internal-elb=1` on private subnets; Auto Mode discovery tags applied for node/LB subnet selection.
- **DNS**: `enable_dns_hostnames` and `enable_dns_support` always true.
- **BYO-VPC in air-gapped networks**: when `create_vpc=false` and profile is `airgapped`, the module validates (via data sources where possible) that required endpoints/tags exist and documents them.

### 3.3 EKS modernization (Requirement 3)

Upgrade `terraform-aws-modules/eks/aws` from the v19.21.0 commit pin to **v21.x** from the registry.

Key changes:
- **Access entries** replace `manage_aws_auth_configmap`. Set `authentication_mode = "API"` (or `API_AND_CONFIG_MAP` transitionally). The `eks_cluster_admin_role_arns` list (already on `dev/pmp`) maps to `access_entries` with the `AmazonEKSClusterAdminPolicy` access policy instead of `system:masters` groups in the configmap. This directly resolves the existing `# TODO: use access_entries` in `variables.tf`.
- **Auto Mode** (POC-gated, §4). When enabled:

  ```hcl
  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]   # or custom NodePools via NodeClass
  }
  ```

  Auto Mode supplies compute, the VPC CNI, EBS CSI, and load balancing as managed components, so the module removes the explicit `aws-ebs-csi-driver` addon IRSA, the AWS Load Balancer Controller install, and any cluster-autoscaler wiring (Requirement 3.7). The cluster IAM role gets the Auto Mode managed policies, plus permissions to manage any custom (non-`eks-cluster-sg-*`) security groups the module attaches (see §5 migration notes).
- **Optional FIPS node cryptography (Requirement 3.10, default OFF)**: the module optionally enables FIPS-validated node cryptography via EKS Auto Mode's node FIPS setting `spec.advancedSecurity.fips: true` on a **custom NodeClass**, defaulting to OFF for the demo. Auto Mode's default `general-purpose`/`system` node pools cannot be modified, so enabling FIPS requires a **custom NodePool + NodeClass** rather than the built-in pools. Auto Mode's FIPS AMIs provide FIPS 140-2 validated modules (available in US regions including GovCloud, since Oct 2025).
- **Contingency only (not built unless triggered, §4/§5)**: if Auto Mode cannot run air-gapped, introduce a Bottlerocket managed node group + Karpenter + AWS LBC + EBS CSI addon. This is documented as a fallback, not carried in the module — both target partitions (commercial, GovCloud) offer Auto Mode. See §5.
- **CoreDNS**: with Auto Mode, node-local DNS is used; the traditional CoreDNS deployment is not needed.

### 3.4 Ingress / routing (Requirement 2.9)

**Decision: classic Kubernetes `Ingress` only.** Gateway API is intentionally out of scope (rationale below).

- **Mendix operator config**: `endpoint.type = ingress`. The operator emits an `Ingress` per app environment; NGINX is removed entirely (superseding the `dev/pmp` `enable_ingress_nginx = false`).
- **Auto Mode built-in ALB**: routing uses Auto Mode's built-in ALB via `IngressClass` (`eks.amazonaws.com/alb`) — **no load balancer controller to install or maintain**.
- **Scheme**: `service.beta.kubernetes.io/aws-load-balancer-scheme: internal` (or the Auto Mode ALB equivalent annotation) for the `airgapped` profile — no public endpoint. `connected` may use internet-facing for iteration.
- **TLS**: terminated at the ALB; for `airgapped`, an internal/provided CA replaces public ACME (the current `letsencrypt-prod` cluster issuer is connected-only).

**Why not Gateway API:** EKS Auto Mode's built-in load balancer controller does not support Gateway API (confirmed via AWS re:Post). Adopting it would require either installing a separate Gateway controller (e.g., Envoy Gateway) on Auto Mode, or running the self-managed AWS LBC (v3.0.0+ supports Gateway API GA) — in both cases a self-managed component we would maintain long-term but not demonstrate. Gateway API is the strategic future direction for Kubernetes routing, but there is no functional need for it in this solution today, and classic `Ingress` is fully supported by both Auto Mode and the Mendix operator. Gateway API is therefore deferred as a future enhancement, not carried as unused IaC (YAGNI). No `routing_mode` variable is introduced.

### 3.5 Dependency vendoring / prestaging (Requirement 5)

Runtime consumption model is decided (pull from ECR/S3/internal repos); the **staging mechanism** is the design decision here.

**Chosen approach: a manifest-driven staging helper plus parameterized source locations.**

- A checked-in **artifact manifest** (`vendor/manifest.yaml` or similar) enumerates every external dependency with pinned version + digest: `mxpc-cli` binary, RDS CA bundle, Mendix registry images (`private-cloud.registry.mendix.com/...`), `pmp-pipeline-tools`, PMP/PCLM Helm charts, GitLab charts and images, observability charts/images, Terraform providers/modules, and the mxbuild package.
- A **staging helper** (script or short-lived CodeBuild/GitLab CI job) reads the manifest and populates ECR (images) and S3 (files/charts/binaries). Where a controlled egress exists it can pull from upstream; otherwise the same manifest is used out-of-band (e.g., on a connected staging host, exported, and imported into the air-gapped environment). Mendix's `installer init migrate` is used for its images.
- **Parameterized source locations** (Requirement 5.7): every consumer reads its source from a Terraform input with a sensible default:

  ```hcl
  variable "artifact_sources" {
    type = object({
      ecr_registry      = optional(string)  # defaults to this account's ECR
      s3_artifact_bucket = optional(string)
      helm_repo_url      = optional(string)  # internal OCI/Helm repo
    })
    default = {}
  }
  ```
- **ECR pull-through cache** is used where a controlled egress exists (`modules/container-registry` extended with `aws_ecr_pull_through_cache_rule`), avoiding manual mirroring.
- **Rationale over alternatives**: a prebuilt "everything" container image was rejected as the primary mechanism because it couples tool versions to image rebuilds and is heavier to audit; the manifest + ECR/S3 approach is transparent, reproducible (digests), and maps directly to how classified staging workflows actually move artifacts. A tooling image MAY still be produced for the CI runner itself.
- **Documentation** (Requirement 5.9): the manifest doubles as the "what must be prestaged and where" artifact for the presentation.

### 3.6 SSO / OIDC identity (Requirement 4)

The module treats the IdP as an **external, pluggable dependency** — it provisions no identity provider and depends on none. A thin `modules/identity` wires PMP (and cluster access) to a configured OIDC/SAML IdP:
- **Inputs, not infrastructure**: an `oidc_config` object (issuer/discovery URL, client ID, client-secret Secrets Manager ARN, scopes, group claim, group→role mappings) — or SAML metadata — is passed through to the PMP installer/operator config. Any OIDC/SAML-compliant IdP works by changing inputs only.
- **Demo IdP (deployment-time choice, not a module dependency)**: the in-cluster GitLab acts as the OIDC provider. GitLab supports this in all tiers/self-managed with standard OIDC discovery and `groups` claims (verified via GitLab docs), it is already deployed for SCM/CI, and it needs no internet — a good fit for the air-gapped demo. The OAuth application registration in GitLab (client ID/secret) may be created by a thin optional helper or supplied as inputs; either way the module's identity wiring is IdP-agnostic.
- **No IdP is designed-around or bundled**: Cognito and Keycloak are intentionally not built in (YAGNI); a future environment points the same inputs at its existing IdP.
- **EKS cluster access**: human operators map through federated identity to **access entries** (not static IAM users) — consistent with §3.3.
- **Cert note**: the exercise requires "SAML/OIDC" and names no specific IdP; the GitLab-OIDC demo wiring satisfies it while keeping the module reusable.

### 3.7 Secrets & KMS (Requirement 6)

- All generated secrets (RDS passwords, Grafana admin, GitLab initial root/registry, IdP client secrets, any namespace secrets) are stored in **AWS Secrets Manager**; none are exposed as plaintext outputs. The current `grafana_admin_password` plaintext output is removed in favor of a Secrets Manager ARN.
- **PMP reads its own credentials directly from Secrets Manager via IRSA — not the Secrets Store CSI Driver.** PMP's own credentials (VCS PATs, build cluster token, Grafana API key, MDA/registry keys) are read at runtime by PMP directly from AWS Secrets Manager using **IRSA**. Terraform provisions the `PMP-*` Secrets Manager entries plus an **IRSA role** whose policy grants `secretsmanager:GetSecretValue` / `secretsmanager:DescribeSecret` scoped to the `PMP-*` prefix. Both the IAM policy resource ARNs and the IRSA trust (STS audience / OIDC principal) MUST be **partition-neutral** — derive the partition via `local.partition` / `data.aws_partition.current` (e.g. `arn:${local.partition}:...`, OIDC/STS audience from the partition `dns_suffix`); do **not** hardcode `arn:aws:` or `sts.amazonaws.com`. Secret values never transit Terraform state (entries are referenced by name/ARN, not value).
- **Operator DB/storage-plan secrets are a separate path.** The Mendix operator's database/storage-plan secrets follow a distinct path from PMP's own credentials and are entered at install time for the demo. The Secrets Store CSI Driver is optional and is **not** used for the demo.
- **KMS**: customer-managed keys for EBS, RDS, S3, and Secrets Manager where practical; the existing `kms_key_admin_arns_list` / `kms_key_user_arns_list` variables feed the EKS module and are extended to the CMKs. `aws_ebs_encryption_by_default` is retained.
- Helm values carrying secrets are marked `sensitive` and sourced from Secrets Manager at apply time so they do not appear in plan output or state diffs where avoidable.

### 3.8 PMP install layer (Requirement 7)

The boundary is explicit across **three tiers**:

- **(a) Terraform** provisions the AWS substrate plus the Mx4PC operator foundation.
- **(b) helmfile layer (run via the pipeline)** installs/upgrades PMP — PCLM, the portal, and build tooling — on top of the substrate.
- **(c) PMP's own platform configuration** — build cluster settings, build images, MDA storage, VCS host, observability wiring, and Kubernetes cluster registration — is performed in the **PMP admin panel (GUI)** and captured as a documented **runbook step**, NOT config-as-code. There is no supported API for this configuration, so automating it is out of scope (YAGNI). Basis: Mendix's `configure-k8s` documentation.

"Pipeline-driven" throughout this design refers to tier (b) — PMP install/upgrade — not tier (c).

- **Mx4PC operator bootstrap** stays in Terraform via the existing `helm_release.mendix_installer` → `charts/mendix-installer` pattern, now parameterized by `operator_mode` (§3.12). This is a one-time foundation bootstrap tightly coupled to Terraform outputs (DB/storage plans, IAM roles, OIDC), so it belongs with the thing that produces those inputs. (Requirement 7.6 rationale documented.)
- **PMP itself** is installed via a new `helmfile/` layer using Mendix's documented mechanism (`helmfile` + `mx-pclm-cli`) deploying PCLM, the portal, and build tooling. This layer is **not** reimplemented in Terraform.
- **PCLM prerequisites**: PCLM requires **Mendix Operator >= 2.21.0** and a **dedicated PostgreSQL database**; a separate database/role on the shared RDS instance is acceptable for the demo.
- **Recurring updates**: because PMP releases on a cadence, the helmfile layer is re-appliable declaratively and is invoked from the GitLab pipeline (§3.11) as a distinct stage, decoupled from `terraform apply`. Tier (c) platform configuration remains the manual admin-panel runbook step.
- **Air-gapped sourcing**: for the `airgapped` profile, helmfile references charts/images/binaries from the vendored ECR/S3 sources (§3.5), not `private-cloud.registry.mendix.com` directly.
- **Licensing**: install/test proceeds without a license; a trial license is applied post-stand-up (Requirement 7.7). The helmfile/PCLM config accepts a license input but does not gate on it.

### 3.9 Mendix application lifecycle (Requirement 8)

- **PMP OOTB Kubernetes-native CI/CD** is the default build path. Terraform creates the build namespace, the `mxplatform-cicd` ServiceAccount + Role + RoleBinding (`pods`, `pods/log`: create/get/delete), and surfaces the cluster CA for the operator `customCASecretName` config.
- **MDA storage**: reuses `modules/file-storage` (S3) with IAM for the build pod to read/write MDAs.
- **Cross-namespace / cross-cluster deploy**: build config supports deploying to another namespace/cluster.
- **Air-gapped build**: `pmp-pipeline-tools` image and the mxbuild package come from ECR/S3 (§3.5).
- **Platform-config boundary**: the PMP Kubernetes-native CI/CD, build cluster, build images, and MDA storage settings are set through the **PMP admin panel** and captured as a documented runbook step — tier (c) of §3.8, not config-as-code (Requirement 8.8).
- **VCS**: developers commit to in-cluster GitLab; Studio Pro uses the GitLab repo. Demo flow: create project in GitLab → commit → PMP builds MDA → deploy to target namespace.

### 3.10 Observability (Requirement 9)

- **Metrics backend = AWS Managed Service for Prometheus (AMP)** — the **default** in **both** the commercial (`aws`) and GovCloud (`aws-us-gov`) partitions. AMP is available in both target partitions, and the `aps` / `aps-workspaces` VPC interface endpoints exist in GovCloud. Retaining the `dev/pmp` pattern, an **ADOT collector remote-writes** metrics to an **AMP workspace**, and **Grafana queries AMP** as its single Prometheus datasource.
- **Airgapped reachability**: for the `airgapped` profile, AMP is reached over PrivateLink via the `aps` (control plane) and `aps-workspaces` (ingest/query) VPC interface endpoints — no internet egress. Terraform creating the AMP workspace uses `aps`; the ADOT `remote_write` and Grafana queries use `aps-workspaces`.
- Deploy **Loki + Grafana** via Helm (versions aligned to PMP's validated set: Grafana 12.x). PMP integrates with a **single** Prometheus (the AMP datasource) and a **single** Loki datasource.
- Grafana exposes the API endpoints PMP calls (`/api/health`, `/api/datasources`, datasource proxy, Loki `query_range`, Prometheus labels/values, `/api/ds/query`).
- **CloudWatch logs**: ADOT/fluentbit → CloudWatch retained where CloudWatch is available.
- Grafana admin credential in Secrets Manager (§3.7). Charts/images from vendored sources for the `airgapped` profile.

### 3.11 CI/CD via in-cluster GitLab (Requirement 10)

- **GitLab (Cloud Native Hybrid)** installed via the official Helm chart in `modules/gitlab`. Per GitLab's reference architecture, stateful components are externalized: **PostgreSQL → the module's RDS**, **object storage (artifacts, LFS, registry, uploads) → S3**, keeping only stateless services in-cluster.
- **GitLab Runner** with the **Kubernetes executor** runs CI jobs as on-demand pods; runner cache → S3.
- **Pipeline stages** (`.gitlab-ci.yml` in `pipelines/`):
  1. `validate` — `terraform fmt -check`, `validate`, `tflint`, `tfsec`/`checkov` (fail on high severity)
  2. `plan` — `terraform plan`, plan artifact retained for approver
  3. `approve` — manual gate
  4. `apply` — `terraform apply`
  5. `pmp-install` — runs the helmfile layer (§3.8 tier (b)) as a distinct stage: PMP install/upgrade only

  PMP's own platform configuration (§3.8 tier (c) — build cluster, VCS host, observability wiring, cluster registration) is **not** a pipeline stage; it is the manual admin-panel runbook step. The pipeline covers substrate provisioning and PMP install/upgrade, not platform config-as-code (no supported API exists).
- **Air-gapped operation**: GitLab images/charts, Terraform providers/modules, and tool images come from vendored ECR/S3 (§3.5); GitLab's offline install approach is used for the `airgapped` profile.
- **State backend**: S3 + native S3 state locking (or DynamoDB where required), KMS-encrypted.
- **Least privilege**: the runner's IRSA / execution role is scoped to the managed resources.
- **Alternative**: CodePipeline + CodeBuild (VPC-configured) remains a documented alternative but is not the primary path; it must not hard-depend on github.com.

### 3.12 Operator installer parameterization (Requirements 1.6–1.8)

The `charts/mendix-installer` configmap currently hardcodes `--clusterMode standalone`. It becomes conditional on `operator_mode`:

```
# templated in mendix-installer-configmap.yaml
{{- if eq .Values.operatorMode "connected" }}
./mxpc-cli base-install --namespace mendix -i {{ .Values.namespaceID }} -s {{ .Values.namespaceSecret }} \
  --clusterMode connected --clusterType generic --clusterTag="aws-reference-deployment"
{{- else }}
./mxpc-cli base-install --namespace mendix \
  --clusterMode standalone --clusterType generic --clusterTag="aws-reference-deployment"
{{- end }}
```

The `apply-config` invocations likewise include `-i`/`-s` only in connected mode. The `mxpc-cli` binary and the RDS CA bundle are fetched from vendored sources (not `cdn.mendix.com` / `truststore.pki.rds.amazonaws.com`) for the `airgapped` profile. `namespace_id`/`namespace_secret` remain optional (default `""`), required only when `operator_mode = connected`.

## Data Models

This is an infrastructure module; the "data models" are the Terraform input/output contracts and the key Kubernetes/config objects the module manages.

### Root input variables (new or changed)

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `connectivity_profile` | string | `connected` | `connected` / `airgapped` (§2.1) |
| `operator_mode` | string | `standalone` | Mendix portal registration mode |
| `create_vpc` | bool | `false` | Create VPC vs consume `vpc_id`/subnets |
| `vpc_id` / `vpc_private_subnets` | string / list | `""` / `[]` | BYO-VPC inputs (used when `create_vpc=false`) |
| `vpc_endpoint_services` | list(string) | curated default set | Interface endpoints for the airgapped profile |
| `artifact_sources` | object | `{}` | ECR registry / S3 bucket / Helm repo overrides (§3.5) |
| `namespace_id` / `namespace_secret` | string | `""` | Required only when `operator_mode=connected` |
| `mendix_operator_version` | string | current release | Operator version (no hard Gateway-API dependency) |
| `kubernetes_version` | string | current supported | EKS control-plane version |
| `eks_cluster_admin_role_arns` | list(string) | `[]` | Mapped to access entries (admin policy) |
| `kms_key_admin_arns_list` / `kms_key_user_arns_list` | list(string) | `[]` | CMK administrators/users |
| `oidc_config` | object | `null` | External IdP wiring: issuer/discovery URL, client ID, client-secret ARN, scopes, group→role mappings (no IdP provisioned) |

### Key managed objects

- **EKS access entries**: `{ principal_arn, type, policy_associations[] }` replacing `aws_auth_roles`.
- **Auto Mode compute**: `cluster_compute_config { enabled, node_pools }`.
- **Ingress**: operator-emitted `Ingress` per app env with internal-scheme ALB annotations (Auto Mode built-in ALB, or self-managed LBC ALB in the fallback).
- **Mendix `OperatorConfiguration`**: `endpoint.type = ingress`, ingress class, TLS, custom CA.
- **Vendoring manifest**: list of `{ name, type(image|chart|binary|file), version, digest, upstream, target }`.
- **Secrets Manager entries**: RDS, Grafana, GitLab, IdP client secret (referenced by ARN, never output plaintext).

### Outputs (changed)

- Removed: plaintext `grafana_admin_password`. Added: Secrets Manager ARNs for each managed secret.
- Retained: cluster name/endpoint/CA, VPC IDs/subnets, registry hostname, DB endpoints (non-secret).

## 4. EKS Auto Mode POC (decision gate)

Auto Mode is the preferred compute mode but is not AWS-documented for fully-private clusters. This POC gates the decision before implementation commits to it.

**Hypothesis:** Auto Mode operates in an `airgapped` VPC provided the required VPC endpoints exist, because Auto Mode nodes reach EC2/ECR/STS/eks-auth over PrivateLink rather than the internet.

**POC steps:**
1. Stand up a minimal cluster in an `airgapped` VPC (no NAT/IGW) with the §3.2 endpoint set plus `eks` and `eks-auth`.
2. Enable `cluster_compute_config { enabled = true }` and deploy a trivial workload with an internal `Ingress` (Auto Mode's built-in ALB) and an EBS-backed PVC.
3. Verify: nodes provision, images pull from ECR, the internal load balancer is created, the volume binds.
4. Confirm with public egress fully blocked (SG/NACL deny) that steady state needs no internet.
5. **FIPS dimension**: verify that enabling the Auto Mode FIPS setting (`advancedSecurity.fips`, FIPS 140-2) on a custom NodeClass provisions successfully. This is a validation dimension of the same POC, not a separate gate.

**Decision:**
- **Pass** → adopt Auto Mode as the single compute path; remove EBS CSI addon / LBC / autoscaler wiring.
- **Fail** → introduce the documented contingency (Bottlerocket managed node group + Karpenter + AWS LBC + EBS CSI addon) and record the reason in the migration note and README. This contingency is built only if the POC fails (see §5).

Auto Mode is the sole planned compute path — both target partitions (commercial, GovCloud) offer it. The Mendix operator config, `Ingress` usage, and everything above Layer 1 are unaffected by this decision.

## 5. Backward compatibility & migration (Requirement 11)

Developed on `feat/pmp-modernization` (already branched from `dev/pmp`).

**Preserved from `dev/pmp`:** standalone operator mode (now parameterized), multiple cluster admin roles (now via access entries), BYO-VPC inputs (now behind `create_vpc`), KMS admin/user variables, `cluster_security_group_additional_rules` + validation, optional `namespace_id`/`namespace_secret`, `kubernetes_version` naming.

**Managed-node / Karpenter contingency (documentation-only).** This path is documentation-only and is built only if the Auto Mode air-gap POC (§4) fails (YAGNI). If invoked, it introduces a Bottlerocket managed node group + Karpenter + AWS LBC + EBS CSI addon and records the reason in the migration note and README.

**Superseded (documented):** `enable_ingress_nginx=false` → classic Ingress via internal-scheme ALB; `aws-auth` ConfigMap → access entries; v19.21.0 pin → v21.x; fixed managed node group → Auto Mode; public ACME issuer → internal CA for the airgapped profile; `grafana_admin_password` plaintext output → Secrets Manager ARN.

**Breaking-change / state-move notes** (for the migration doc):
- EKS module v19→v21 and the auth-mode switch can force cluster/role replacement; document `state mv` / targeted apply steps and expect node-group churn. For an existing cluster, prefer the AWS-documented "enable Auto Mode on existing cluster" flow over in-place module surgery where feasible.
- **AWS does not support migrating load balancers from the self-managed AWS LBC to Auto Mode's managed controller.** If moving an existing NGINX/LBC-fronted cluster to Auto Mode, expect to recreate the load balancer / DNS rather than migrate it in place. Plan a cutover for the ingress endpoint.
- Moving to Auto Mode requires uninstalling components it now manages (Karpenter, AWS LBC, EBS CSI) and ensuring addons are current — reference the AWS self-managed → Auto Mode resource-ownership matrix.
- **Custom security groups**: Auto Mode's default managed policy only lets EKS modify security groups named `eks-cluster-sg-*`. The `dev/pmp` cluster uses custom SG rules and attaches the primary SG; if worker nodes end up with custom (non-`eks-cluster-sg-`) security groups, the **cluster IAM role needs additional permissions** so Auto Mode can add the ingress rules that let ALB/NLB reach pods. Account for this in the cluster role policy.

**Variable changes** are documented in README + a `MIGRATION.md`; renamed/removed variables are called out to avoid silent behavior changes.

## 6. Documentation & demo artifacts (Requirement 12)

- README + deployment guide updated for profiles, operator mode, Auto Mode (+ fallback), classic Ingress routing, GitLab CI/CD, SSO, vendoring, and the PMP install layer.
- Architecture overview (diagram + narrative) covering Mendix, PMP, and the demo AWS architecture.
- Runbook: deploy → app lifecycle (create → commit → build → deploy) → day-2 ops (SSM access, upgrades).
- The vendoring manifest (§3.5) serves as the "prestaged artifacts and locations" reference.
- Reflection notes + stated assumptions (see `partner-presentation/mendix-contact-questions.md`).

## Correctness Properties

Invariants the implementation must uphold (verifiable via `check`/`validation` blocks, plan review, or the `airgapped` verification step).

### Property 1: No public egress when air-gapped
When `connectivity_profile = airgapped`, no NAT gateway, no internet gateway, and no component makes an outbound public-internet call at install or steady state. **Validates: Requirements 1.3, 1.10, 5.3**

### Property 2: Single VPC source
Exactly one of {created VPC, supplied VPC} is active; conflicting inputs fail at plan time. **Validates: Requirements 2.1, 2.2, 2.3**

### Property 3: Operator-mode consistency
`operator_mode = connected` implies `connectivity_profile = connected` (the Mendix portal is otherwise unreachable). **Validates: Requirements 1.5, 1.6, 1.7**

### Property 4: Private endpoint when air-gapped
The `airgapped` profile always disables the EKS public API endpoint. **Validates: Requirements 1.4**

### Property 5: No plaintext secrets
No secret value appears in Terraform outputs; all are Secrets Manager references. **Validates: Requirements 6.1, 6.4, 9.6**

### Property 6: Partition neutrality
Across the target partitions {`aws`, `aws-us-gov`}, no hardcoded `aws`-partition ARNs, service endpoints, DNS suffixes, or AMI owner IDs; all derive from data sources — including the PMP secrets-read IAM policy and IRSA trust (STS audience / OIDC principal). **Validates: Requirements 1.8, 1.9, 6.3**

### Property 7: Compute-path independence
The routing layer (classic Ingress), PMP platform, and app-lifecycle layers (Layers 2–4) do not depend on compute internals: they work under Auto Mode and would work unchanged under the managed-node contingency. **Validates: Requirements 3.2, 3.7**

### Property 8: Vendoring completeness
For the `airgapped` profile, every dependency in the manifest resolves to an in-partition source; no consumer references a public upstream at runtime. **Validates: Requirements 5.1, 5.3**

## Error Handling

- **Plan-time validation**: variable `validation` blocks (enum membership) and `check` blocks (operator-mode/profile consistency, `create_vpc` conflict, required VPC endpoints for BYO-VPC airgapped) fail fast with actionable messages before any resource is touched.
- **Auto Mode POC gate**: Auto Mode is adopted only after the §4 POC passes for the airgapped profile; if it fails, the documented managed-node contingency is introduced rather than silently degrading.
- **Installer job failures**: the `mxpc-cli` bootstrap runs as a Kubernetes Job; failures are surfaced via job logs (existing troubleshooting flow retained). Vendored-artifact resolution failures fail the job with the missing artifact name rather than falling back to a public pull.
- **Pipeline failures**: `validate`/`plan`/`apply`/`pmp-install` stages fail closed; high-severity `tfsec`/`checkov` findings block the pipeline (Requirement 10.4). The manual approval gate prevents unreviewed applies.
- **Secret retrieval failures**: missing Secrets Manager entries fail the consuming resource at apply with a clear reference, rather than injecting empty credentials.

## Testing Strategy

- **Static**: `terraform fmt`, `validate`, `tflint`, `tfsec`/`checkov` in the `validate` pipeline stage; no new high-severity findings (Requirement 3.9).
- **Plan-time checks**: `check` blocks and variable `validation` for profile/operator-mode consistency and `create_vpc` conflicts; assert VPC endpoint presence for BYO-VPC `airgapped` profiles.
- **POC (§4)** validates Auto Mode before adoption.
- **Connected-profile smoke test**: full deploy in a commercial account (`connected`, `standalone`) as the fast iteration loop, exercising the end-to-end app lifecycle.
- **Airgapped-profile validation**: deploy with NAT disabled + endpoints, confirm no internet egress (VPC flow logs / deny-all egress SG) — the `airgapped` verification step (Requirement 1.10).
- **Idempotency**: re-apply Terraform and re-run the helmfile layer to confirm no drift and clean upgrades.

## 8. Open items / risks

- **Auto Mode air-gap** (§4) — primary technical risk; mitigated by the POC gate and a documented managed-node contingency (built only if the POC fails).
- **PostgreSQL version** — pinned to **17.x**, driven by the GitLab chart (10.x/GitLab 19.x requires PG 17 minimum). PG 17 is within the Mendix operator's supported range (13–17), supported by RDS, and above PCLM's documented floor of 12. Residual is a low-risk confirmation checkbox that PCLM runs on 17 — not a compatibility risk.
- **GitLab weight** — full GitLab is heavy for a demo; externalizing state to RDS/S3 and using the Runner Kubernetes executor keeps it manageable, but sizing must be validated against the PMP prerequisite hardware minimums.
- **Partition feature gaps (commercial + GovCloud)** — AMP is the metrics backend, reached via the `aps` / `aps-workspaces` VPC interface endpoints for the `airgapped` profile. SSO is IdP-agnostic (external OIDC/SAML), so no identity service needs to exist in-partition. Validate specifics in the target partition.
- **FIPS** — optional Auto Mode FIPS 140-2 toggle, available in GovCloud; default OFF.
- **Operator version** — target **>= 2.21.0** (PCLM prerequisite); there is no hard Gateway-API dependency now that Gateway API is out of scope (classic Ingress works on the current operator line). Validate the upgrade path from 2.20.1 for any existing installation.
- **Gateway API** — deferred as a future enhancement (§3.4); not built or maintained in this iteration.
