# Implementation Plan: PMP on AWS — Modernization & Air-Gapped Delivery

## Overview

This plan implements the layered design in `design.md` for the `terraform-aws-mendix-private-cloud`
module on branch `feat/pmp-modernization`. Implementation language is **Terraform/HCL** for Layers 0–2
(the design is concrete HCL, not pseudocode), with **helmfile + YAML** for the PMP install layer,
**GitLab CI YAML** for pipelines, and **shell** for the vendoring staging helper.

Sequencing is driven by three hard constraints from the design and handoff:

1. **Task 1 is a decision gate.** The EKS Auto Mode air-gap POC (design §4) runs first. No task that
   *enables* Auto Mode on the real module (compute config, built-in ALB ingress, removal of
   EBS-CSI/LBC/autoscaler) is scheduled until the POC passes. The managed-node + Karpenter path is a
   **documented contingency only** — it is NOT built unless the POC fails.
2. **The main sizing risk is surfaced early** as an explicit task: GitLab footprint sizing vs PMP hardware minimums (Task 4). PostgreSQL is pinned to **17.x** (Task 3), a GitLab-chart-driven choice (GitLab Helm chart 10.x / GitLab 19.x requires PG17 minimum). PG17 is within the Mendix operator's supported range (13–17), supported by RDS, and above PCLM's documented floor of 12, so it carries only a low-risk confirmation — not a three-way compatibility risk.
3. **YAGNI/KISS.** No speculative generality. Tasks that could invite it are flagged inline; Gateway API, extra IdPs, and the managed-node path are explicitly excluded from build scope. Task groupings and requirement references follow the design's requirement-to-section traceability table
and the §3.1 module structure.

## Tasks

- [ ] 1. EKS Auto Mode air-gap POC — DECISION GATE (design §4)
  - [ ] 1.1 Build a self-contained, throwaway POC harness
    - Create a minimal Terraform config (isolated from the production root) standing up an `airgapped`
      VPC with **no NAT/IGW** and the §3.2 endpoint set plus `eks` and `eks-auth`
    - Provision a minimal EKS cluster (v21.x) with `cluster_compute_config { enabled = true, node_pools = ["general-purpose"] }`
    - _Requirements: 3.2, 2.6, 1.4_
  - [ ] 1.2 Deploy a trivial workload and verify managed components
    - Deploy a stub app with an internal-scheme `Ingress` (Auto Mode built-in ALB `IngressClass`) and an EBS-backed PVC
    - Add automated verification asserting: nodes provision, image pulls from ECR succeed, the internal ALB is created, and the PVC binds
    - _Requirements: 3.2, 2.9_
  - [ ] 1.3 Prove no-egress steady state and record the gate outcome
    - Apply a deny-all public-egress SG/NACL and confirm via VPC flow logs that steady state needs no internet
    - Record PASS/FAIL in a POC note; on PASS, Auto Mode is adopted as the single compute path; on FAIL, open the managed-node contingency per §5 (built only then)
    - _Requirements: 1.3, 1.10, 3.8_
  - [ ] 1.4 Verify the FIPS validation dimension of the POC
    - Enable the Auto Mode FIPS setting (`advancedSecurity.fips`, FIPS 140-2) on a **custom NodeClass** and confirm nodes provision successfully — this is a validation dimension of the POC, NOT a new gate
    - _Requirements: 3.10_

- [ ] 2. Establish connectivity-profile and partition-neutral foundation (design §2)
  - [ ] 2.1 Add core selector variables with validation
    - Add `connectivity_profile` (connected|airgapped) and `operator_mode` (connected|standalone) to `variables.tf` with enum `validation`
    - _Requirements: 1.1, 1.5_
  - [ ] 2.2 Add derived locals, partition data sources, and cross-variable checks
    - Add `local.allow_internet_egress`, `create_nat_gateway`, `need_vpc_endpoints`, `partition`, `dns_suffix` in `main.tf`
    - Add the `operator_mode_consistency` `check` block and the `create_vpc` conflict `check` block
    - _Requirements: 1.7, 1.8, 2.3_
  - [ ]* 2.3 Write property test for operator-mode consistency
    - **Property 3: Operator-mode consistency**
    - **Validates: Requirements 1.5, 1.6, 1.7**
  - [ ]* 2.4 Write property test for partition neutrality
    - **Property 6: Partition neutrality** (assert ARNs/endpoints/DNS/AMI owners are derived dynamically across the target partitions {`aws`, `aws-us-gov`} and never hardcoded, including the PMP secrets-read IAM policy and IRSA trust)
    - **Validates: Requirements 1.8, 1.9, 6.3**

- [ ] 3. De-risk PostgreSQL 17 pin — GitLab-chart-driven (design §8)
  - [ ] 3.1 Pin PostgreSQL 17 in `modules/databases` with per-consumer parameter groups
    - Set the RDS engine version to 17.x — driven by the pinned GitLab chart (GitLab Helm chart 10.x / GitLab 19.x requires PG17 minimum); PG17 is within the Mendix operator range (13–17), supported by RDS, and above PCLM's floor of 12
    - Allow per-consumer version/parameter-group pinning for Mx4PC/PCLM vs GitLab if needed
    - PCLM requires **Mendix Operator >= 2.21.0** and a **dedicated PostgreSQL database**; provision a separate database/role on the shared RDS instance (acceptable for the demo)
    - _Requirements: 6.2, 10.2, 7.8_
  - [ ]* 3.2 Confirm PCLM-on-17 and align the GitLab chart version
    - Low-risk confirmation that PCLM runs on PostgreSQL 17, plus a GitLab-chart-version alignment check that the pinned chart's minimum PG matches the 17.x pin; fail with the offending consumer named
    - _Requirements: 7.1, 7.8, 10.2_

- [ ] 4. De-risk GitLab footprint sizing vs PMP minimums — HIGH RISK (design §8)
  - [ ] 4.1 Produce sized GitLab CNH Helm values
    - Author `modules/gitlab` values with resource requests/limits and externalized state (PostgreSQL→RDS, object storage→S3), sized so the GitLab footprint plus PMP fits the PMP prerequisite hardware minimums
    - _Requirements: 10.2_
  - [ ]* 4.2 Validate cluster compute capacity against the sizing
    - Encode the sizing assumptions and assert requested capacity is consistent with the Auto Mode `general-purpose` pool expectations; document the headroom
    - _Requirements: 10.2_

- [ ] 5. VPC / networking module (design §3.2)
  - [ ] 5.1 Add `create_vpc` toggle and single-source indirection
    - Extend `modules/vpc` so the root passes either created outputs or supplied `vpc_id`/subnets through one `local.vpc_id`/`local.private_subnets` indirection consumed by EKS/RDS/endpoints
    - _Requirements: 2.1, 2.2, 2.3_
  - [ ] 5.2 Add profile-driven networking, endpoints, tags, and DNS
    - Gate NAT/IGW on `local.create_nat_gateway`; when `need_vpc_endpoints`, create the interface/gateway endpoint set (incl. `eks`, `eks-auth`, and `aps` + `aps-workspaces` for AWS Managed Service for Prometheus) as a parameterized list; apply `kubernetes.io/role/internal-elb` + Auto Mode discovery tags; force `enable_dns_hostnames`/`enable_dns_support`
    - _Requirements: 2.4, 2.5, 2.6, 2.7_
  - [ ] 5.3 Validate BYO-VPC in airgapped
    - When `create_vpc=false` and `airgapped`, validate (via data sources where possible) and document the required endpoints/tags
    - _Requirements: 2.8_
  - [ ]* 5.4 Write property test for single VPC source
    - **Property 2: Single VPC source** (conflicting inputs fail at plan time)
    - **Validates: Requirements 2.1, 2.2, 2.3**
  - [ ]* 5.5 Write property test for no public egress when air-gapped
    - **Property 1: No public egress when air-gapped** (no NAT/IGW created under `airgapped`)
    - **Validates: Requirements 1.3, 1.10, 5.3**

- [ ] 6. Checkpoint — Ensure all tests pass, ask the user if questions arise.

- [ ] 7. EKS modernization — Auto Mode + access entries (design §3.3) — depends on Task 1 PASS
  - [ ] 7.1 Upgrade the EKS module and switch to access entries
    - Move `terraform-aws-modules/eks/aws` from the v19.21.0 commit pin to v21.x (registry); set `authentication_mode = "API"` (or `API_AND_CONFIG_MAP` transitionally); map `eks_cluster_admin_role_arns` to `access_entries` with `AmazonEKSClusterAdminPolicy`, resolving the `# TODO: use access_entries`
    - _Requirements: 3.1, 3.4_
  - [ ] 7.2 Enable Auto Mode and remove superseded components
    - Set `cluster_compute_config { enabled = true, node_pools = ["general-purpose"] }`; add cluster IAM role permissions for custom (non-`eks-cluster-sg-*`) security groups; remove EBS CSI IRSA, AWS Load Balancer Controller, and cluster-autoscaler wiring
    - Do NOT introduce the managed-node/Karpenter path (contingency only, §5) — flag if any reviewer requests it pre-trigger. The contingency is documentation-only and built only if the Task 1 POC fails
    - _Requirements: 3.2, 3.3, 3.5, 3.7_
  - [ ] 7.3 Enforce private API endpoint for airgapped
    - Disable EKS public endpoint and enable private access when `connectivity_profile = airgapped`
    - _Requirements: 1.4_
  - [ ]* 7.4 Write property test for private endpoint when air-gapped
    - **Property 4: Private endpoint when air-gapped**
    - **Validates: Requirements 1.4**
  - [ ]* 7.5 Write property test for compute-path independence
    - **Property 7: Compute-path independence** (routing/PMP/app layers do not reference compute internals)
    - **Validates: Requirements 3.2, 3.7**
  - [ ] 7.6 Add the optional FIPS node-cryptography toggle (default OFF)
    - Optionally enable FIPS 140-2 validated node crypto via `advancedSecurity.fips: true` on a **custom NodeClass/NodePool**, defaulting OFF for the demo; note that Auto Mode's default `general-purpose`/`system` pools cannot be modified, so FIPS requires a custom NodePool + NodeClass. Auto Mode's FIPS AMIs are available in GovCloud (`aws-us-gov`)
    - YAGNI: do NOT build the managed-node/Karpenter contingency now — it is documentation-only and built only if the Task 1 POC fails (§5)
    - _Requirements: 3.10_

- [ ] 8. Ingress / routing via Auto Mode built-in ALB (design §3.4) — depends on Task 1 PASS
  - [ ] 8.1 Configure classic Ingress and remove NGINX
    - Set operator `endpoint.type = ingress`; use the Auto Mode built-in ALB `IngressClass` (`eks.amazonaws.com/alb`) with `internal` scheme for `airgapped`; remove the NGINX dependency entirely
    - Gateway API is out of scope — do NOT add a `routing_mode` variable or a Gateway controller (YAGNI)
    - _Requirements: 2.9_
  - [ ] 8.2 Wire TLS termination and internal CA
    - Terminate TLS at the ALB; replace the public ACME `letsencrypt-prod` issuer with an internal/provided CA for `airgapped`
    - _Requirements: 2.9, 6.2_

- [ ] 9. Dependency vendoring / prestaging (design §3.5)
  - [ ] 9.1 Author the artifact manifest
    - Create `vendor/manifest.yaml` enumerating every external dependency with pinned version + digest (mxpc-cli, RDS CA bundle, Mendix registry images, pmp-pipeline-tools, PMP/PCLM charts, GitLab charts/images, observability charts/images, Terraform providers/modules, mxbuild)
    - _Requirements: 5.1, 5.5_
  - [ ] 9.2 Build the manifest-driven staging helper
    - Create a script/CI job that reads the manifest and populates ECR (images) and S3 (files/charts/binaries); use Mendix `installer init migrate` for its images; support both controlled-egress pull and out-of-band import
    - _Requirements: 5.2, 5.3_
  - [ ] 9.3 Create `modules/vendoring` and wire parameterized sources
    - Provision ECR repos and S3 artifact buckets; add the `artifact_sources` object input (ecr_registry / s3_artifact_bucket / helm_repo_url) with sensible defaults consumed by every downstream module
    - _Requirements: 5.6, 5.7_
  - [ ]* 9.4 Write property test for vendoring completeness
    - **Property 8: Vendoring completeness** (every airgapped dependency resolves to an in-partition source)
    - **Validates: Requirements 5.1, 5.3**

- [ ] 10. Container registry extension (design §3.5)
  - [ ] 10.1 Add pull-through cache and mirrored repos
    - Extend `modules/container-registry` with `aws_ecr_pull_through_cache_rule` used where controlled egress exists, plus mirrored repositories fed by the staging helper
    - _Requirements: 5.2_

- [ ] 11. Secrets & KMS (design §3.7)
  - [ ] 11.1 Route all secrets to Secrets Manager, add PMP-native IRSA read, and add CMKs
    - Store RDS/Grafana/GitLab/IdP secrets in Secrets Manager (ARNs only, no plaintext); remove the `grafana_admin_password` plaintext output; extend `kms_key_admin_arns_list`/`kms_key_user_arns_list` to CMKs for EBS/RDS/S3/Secrets Manager; mark secret-bearing Helm values `sensitive`
    - Provision the `PMP-*` Secrets Manager entries plus an **IRSA role** whose policy grants `secretsmanager:GetSecretValue`/`secretsmanager:DescribeSecret` scoped to the `PMP-*` prefix; PMP reads these directly at runtime (NOT via the Secrets Store CSI Driver)
    - Make the IAM policy resource ARNs and the IRSA trust (STS audience / OIDC principal) **partition-neutral** — derive the partition (`local.partition` / `data.aws_partition.current`); do NOT hardcode `arn:aws:` or `sts.amazonaws.com`
    - Note: the Mendix operator DB/storage-plan secrets follow a separate path entered at install time for the demo; the Secrets Store CSI Driver is optional and unused
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 9.6_
  - [ ]* 11.2 Write property test for no plaintext secrets
    - **Property 5: No plaintext secrets** (no secret value in outputs; all Secrets Manager references)
    - Extend scope to also assert the PMP secrets-read IAM policy and IRSA trust use partition-neutral ARNs (complements Property 6)
    - **Validates: Requirements 6.1, 6.3, 6.4, 9.6**

- [ ] 12. Checkpoint — Ensure all tests pass, ask the user if questions arise.

- [ ] 13. Identity / SSO wiring (design §3.6)
  - [ ] 13.1 Create `modules/identity` as pluggable OIDC/SAML passthrough
    - Accept an `oidc_config` object (issuer/discovery URL, client ID, client-secret Secrets Manager ARN, scopes, group→role mappings) or SAML metadata; provision NO IdP; source the client secret from Secrets Manager
    - Do NOT bundle Cognito/Keycloak or design around any specific IdP (YAGNI)
    - _Requirements: 4.1, 4.2, 4.3, 4.4_
  - [ ] 13.2 Map human operators to EKS access entries via federation
    - Map federated identity to access entries/access policies rather than static IAM users
    - _Requirements: 4.5_
  - [ ] 13.3 Provide GitLab-as-OIDC demo wiring
    - Optional thin helper (or inputs) to register the GitLab OAuth application; keep the identity wiring IdP-agnostic — GitLab-OIDC is the demo's choice, not a module dependency
    - _Requirements: 4.3, 4.6_

- [ ] 14. In-cluster GitLab: SCM + CI/CD platform (design §3.11)
  - [ ] 14.1 Install GitLab CNH with externalized state
    - Deploy the official GitLab cloud-native Helm chart in `modules/gitlab`; externalize PostgreSQL→RDS and object storage (artifacts, LFS, registry, uploads)→S3, keeping stateless services in-cluster (consumes the Task 3 DB and Task 4 sizing)
    - _Requirements: 10.1, 10.2_
  - [ ] 14.2 Configure the GitLab Runner Kubernetes executor
    - Deploy GitLab Runner with the Kubernetes executor (CI jobs as on-demand pods); route runner cache→S3; scope the runner IRSA/execution role to least privilege
    - _Requirements: 10.3, 10.10_

- [ ] 15. Observability stack (design §3.10)
  - [ ] 15.1 Deploy AMP-backed metrics with Loki + Grafana via Helm
    - Adjust `modules/monitoring` so AWS Managed Service for Prometheus (AMP) is the DEFAULT and only planned metrics backend in BOTH `aws` and `aws-us-gov`. Retain the `dev/pmp` pattern: an ADOT collector remote-writes metrics to an AMP workspace and Grafana queries AMP as its single Prometheus datasource
    - Deploy Loki + Grafana via Helm (Grafana 12.x, aligned to PMP's validated set); configure a single Prometheus (the AMP datasource) and a single Loki datasource; expose the Grafana API endpoints PMP requires
    - For `airgapped`, reach AMP over PrivateLink via the `aps` (control plane / workspace create) and `aps-workspaces` (ingest/query) VPC interface endpoints (Task 5.2) with no internet egress
    - _Requirements: 9.1, 9.2, 9.3, 9.4_
  - [ ] 15.2 Source Grafana credential and charts securely
    - Store the Grafana admin credential in Secrets Manager; source Grafana/Loki/ADOT charts/images from vendored in-partition sources for `airgapped`
    - _Requirements: 9.5, 9.6_

- [ ] 16. Checkpoint — Ensure all tests pass, ask the user if questions arise.

- [ ] 17. Mendix operator bootstrap parameterization (design §3.12)
  - [ ] 17.1 Parameterize the installer configmap by `operator_mode`
    - Template `charts/mendix-installer/templates/mendix-installer-configmap.yaml` to emit `--clusterMode connected` (with `-i`/`-s`) or `--clusterMode standalone` (omitting `-i`/`-s`); keep `namespace_id`/`namespace_secret` optional, required only when connected
    - _Requirements: 1.5, 1.6, 7.6_
  - [ ] 17.2 Source installer artifacts from vendored locations
    - Fetch `mxpc-cli` and the RDS CA bundle from ECR/S3 (not `cdn.mendix.com`/`truststore.pki.rds.amazonaws.com`) for `airgapped`
    - _Requirements: 1.3, 5.3_

- [ ] 18. PMP install/upgrade layer via helmfile (design §3.8, tier b)
  - [ ] 18.1 Create the `helmfile/` layer (install/upgrade only)
    - Add `helmfile.yaml` + values deploying PCLM, portal, and build tooling via helmfile + `mx-pclm-cli`; make it repeatable/re-appliable for PMP's release cadence, decoupled from `terraform apply`
    - Scope is PMP **install/upgrade only** (tier b); PMP platform configuration is the manual admin-panel runbook step (tier c, Task 19.4) and is NOT part of this layer. Requires Mendix Operator >= 2.21.0 and the dedicated PCLM PostgreSQL database (Task 3)
    - _Requirements: 7.1, 7.2, 7.3, 7.8_
  - [ ] 18.2 Wire airgapped sourcing and non-gating license
    - Reference charts/images/binaries from vendored ECR/S3 for `airgapped`; accept a license input without gating install on it
    - _Requirements: 7.5, 7.7_

- [ ] 19. Mendix application lifecycle wiring (design §3.9)
  - [ ] 19.1 Create the build namespace and CICD RBAC
    - Create the build namespace and the `mxplatform-cicd` ServiceAccount + Role + RoleBinding granting `pods` and `pods/log` (`create`, `get`, `delete`)
    - _Requirements: 8.1, 8.2_
  - [ ] 19.2 Surface the cluster CA and MDA storage
    - Make the cluster CA available for the operator `customCASecretName`; provision S3 MDA storage with build-pod IAM read/write
    - _Requirements: 8.3, 8.4_
  - [ ] 19.3 Enable cross-namespace/cluster deploy and airgapped build sourcing
    - Support deploying to another namespace/cluster; serve `pmp-pipeline-tools` and the mxbuild package from ECR/S3 for `airgapped`
    - _Requirements: 8.5, 8.6, 8.7_
  - [ ] 19.4 Document the PMP admin-panel platform-configuration runbook (tier c)
    - Write a dedicated runbook (`doc/pmp-admin-config-runbook.md`) capturing the PMP platform configuration performed in the **PMP admin panel (GUI)**: build cluster settings, build images, MDA storage, VCS host, observability wiring, and Kubernetes cluster registration
    - Captured as a documented runbook step, NOT config-as-code — there is no supported API, so automating it is out of scope (YAGNI)
    - _Requirements: 7.1, 7.4, 8.8_

- [ ] 20. CI/CD pipeline definitions (design §3.11)
  - [ ] 20.1 Author the GitLab CI pipeline stages
    - Create `pipelines/.gitlab-ci.yml` with `validate` (`fmt -check`, `validate`, `tflint`, `tfsec`/`checkov` failing on high severity), `plan` (retained plan artifact for approver), `approve` (manual gate), `apply`, and `pmp-install` (runs the helmfile layer as a distinct stage)
    - The `pmp-install` stage is PMP **install/upgrade only** (tier b) — NOT platform config; PMP admin-panel configuration (tier c) is the manual runbook step (Task 19.4), not a pipeline stage (no supported API)
    - _Requirements: 10.4, 10.5, 10.7, 10.8, 7.4_
  - [ ] 20.2 Configure remote state and least-privilege identity
    - Use S3 + native state locking, KMS-encrypted; scope the pipeline execution identity to the resources it manages
    - _Requirements: 10.6, 10.10_
  - [ ] 20.3 Wire airgapped offline operation
    - Obtain GitLab images/charts, Terraform providers/modules, and tool images from in-partition sources using GitLab's offline install approach
    - _Requirements: 10.9_

- [ ] 21. Checkpoint — Ensure all tests pass, ask the user if questions arise.

- [ ] 22. Backward compatibility & migration (design §5)
  - [ ] 22.1 Write MIGRATION.md and reconcile variable changes
    - Document v19→v21 upgrade, `aws-auth`→access-entries switch, Auto Mode enablement (prefer the AWS "enable on existing cluster" flow), load-balancer recreation (no LBC→Auto-Mode LB migration), custom-SG cluster-role permissions, and required `state mv`/targeted-apply steps; call out renamed/removed variables in README + MIGRATION.md to avoid silent behavior changes
    - _Requirements: 11.1, 11.2, 11.4_

- [ ] 23. Documentation & demo artifacts (design §6)
  - [ ] 23.1 Update README and deployment guide
    - Reflect connectivity profiles, operator mode, Auto Mode (+ contingency note), classic Ingress routing, GitLab CI/CD, SSO, vendoring, and the PMP install layer
    - _Requirements: 12.1_
  - [ ] 23.2 Produce the architecture overview
    - Add a concise architecture narrative plus a diagram-as-code (mermaid/PlantUML) covering Mendix, PMP, and the demo AWS architecture
    - _Requirements: 12.2_
  - [ ] 23.3 Write the runbook, reflection notes, and prestaged-artifacts reference
    - Step-by-step deploy → app lifecycle (create → commit → build → deploy) → day-2 ops; reflection notes + explicit assumptions; use `vendor/manifest.yaml` as the prestaged-artifacts-and-locations reference
    - _Requirements: 12.3, 12.4, 12.5, 5.8_

- [ ] 24. Final checkpoint — Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional (property/compatibility tests) and can be skipped for a faster MVP.
- **Property tests are Terraform-native** (`terraform test` / `.tftest.hcl` plan assertions and `check`
  blocks), not runtime PBT libraries — the correctness properties are plan-time invariants and the
  `airgapped` verification step, per the design's Correctness Properties section.
- **Task 1 is a decision gate.** Tasks 7.2, 7.6, 8.1, and 8.2 (Auto Mode compute, FIPS toggle, built-in
  ALB ingress) are scheduled only after the POC passes. The managed-node + Karpenter + AWS LBC + EBS CSI
  contingency is documentation-only and is built (under Task 7) only if the Task 1 POC fails, with the
  reason recorded in MIGRATION.md/README — it is not built otherwise. Auto Mode's optional FIPS toggle
  (Task 7.6) provides FIPS 140-2 validated node cryptography and is available in GovCloud.
- **Partition scope:** commercial (`aws`) and GovCloud (`aws-us-gov`).
- **YAGNI flags applied:** no Gateway API / `routing_mode` variable (Task 8.1), no bundled IdP
  (Task 13.1), no managed-node/Karpenter path unless the Task 1 POC fails (Tasks 7.2, 7.6), and no
  config-as-code for PMP admin-panel platform configuration (Task 19.4 is a documented runbook, no
  supported API). Reviewers requesting these before a demonstrated need should be pointed at the design's
  YAGNI rationale (§3.4, §3.6, §3.8, §4).
- **Component scope:** only PCLM plus the portal and build tooling are installed. Svix (webhooks), Maia
  (LLM assistant), PDF DocGen, and Marketplace are out of scope (not required by the certification).
- **Install vs. configuration boundary:** the helmfile layer (Task 18) and the `pmp-install` pipeline stage
  (Task 20.1) cover PMP install/upgrade only (tier b). PMP platform configuration (tier c) is the manual
  admin-panel runbook step (Task 19.4).
- Out of scope and intentionally absent: Studio Pro app modeling,
  and multi-region/multi-account landing-zone automation.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1"] },
    { "id": 1, "tasks": ["1.2", "2.2", "3.1", "4.1", "5.1", "9.1"] },
    { "id": 2, "tasks": ["1.3", "1.4", "2.3", "2.4", "3.2", "4.2", "5.2", "9.2", "10.1"] },
    { "id": 3, "tasks": ["5.3", "7.1", "9.3", "11.1", "13.1", "14.1", "15.1", "17.1"] },
    { "id": 4, "tasks": ["5.4", "5.5", "7.2", "9.4", "11.2", "13.2", "13.3", "14.2", "15.2", "17.2"] },
    { "id": 5, "tasks": ["7.3", "8.1", "18.1", "19.1", "20.1"] },
    { "id": 6, "tasks": ["7.4", "7.5", "7.6", "8.2", "18.2", "19.2", "19.3", "20.2", "20.3"] },
    { "id": 7, "tasks": ["19.4", "22.1", "23.1", "23.2"] },
    { "id": 8, "tasks": ["23.3"] }
  ]
}
```
