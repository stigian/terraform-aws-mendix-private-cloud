# Requirements Document

Private Mendix Platform (PMP) on AWS: Modernization & Air-Gapped Delivery

## Introduction

This feature modernizes the existing `terraform-aws-mendix-private-cloud` module (currently on the `dev/pmp` branch) to meet the Mendix Private Mendix Platform (PMP) **Partner Certification** requirements and bring the AWS infrastructure up to current best practices.

The certification exercise requires a working, **air-gapped** PMP instance integrated with Source Control (git), Single Sign-On (SAML/OIDC), and CI/CD (OOTB or integrated), plus an end-to-end Mendix app development and deployment lifecycle from Studio Pro to the target cluster. See `partner-presentation/PMP-Partner Certification Exercise.md` for the source requirements.

Beyond the certification demo, this module is intended to be reusable for ordinary private Mendix deployments. It targets two network states — **`connected`** (outbound internet allowed, for iteration and learning) and **`airgapped`** (no internet egress; the cluster reaches only its own AWS partition's control plane via VPC endpoints). The target partition set is **commercial (`aws`) and GovCloud (`aws-us-gov`)** only; both offer EKS Auto Mode (AWS announced Auto Mode in GovCloud in October 2025), which remains the single compute path. The module is still written to be **partition-neutral** because GovCloud requires `aws-us-gov` ARNs, service endpoints, and DNS suffixes to be derived dynamically rather than hardcoded. The requirements are ordered to mirror the intended design and build-up order: connectivity framing first, then network, compute, identity, supply chain, secrets, platform install, app lifecycle, observability, automation, and finally migration and documentation.

### Scope summary

In scope:
- A two-state connectivity model (`connected` / `airgapped`) plus partition-neutral construction that the rest of the module keys off of.
- An explicit, reusable VPC/networking module supporting both create-new and use-existing VPC.
- Upgrade EKS to a modern, low-ops posture: EKS Auto Mode, `terraform-aws-eks` v20+, access entries.
- Optional FIPS-compliant node cryptography, disabled by default for the demo but supported for government/regulated reuse.
- SSO integration via a pluggable, external OIDC/SAML identity provider (module provisions none).
- Vendoring/mirroring of all external dependencies (Terraform modules/providers, binaries, container images, Helm charts) into in-partition ECR/S3 for the air-gapped path.
- Secrets management.
- The PMP install/upgrade layer (helmfile-based) layered on top of the Terraform-provisioned foundation, driven through CI/CD since PMP updates on a recurring release cadence.
- Wiring for the Mendix application build/deploy lifecycle (PMP OOTB Kubernetes-native CI/CD).
- Observability stack compatible with PMP (AWS Managed Service for Prometheus / Grafana / Loki).
- CI/CD for the infrastructure, PMP layer, and app delivery using **self-hosted GitLab** (VCS + GitLab CI) deployed in-cluster, with policy gates. This is intended as reusable infra-CI/CD, not just a demo artifact.
- Documentation and demo artifacts to support the certification presentation.

Out of scope (this iteration):
- Building the Mendix application model itself (Studio Pro modeling work).
- Multi-region / multi-account landing-zone automation.
- A non-Auto-Mode compute path (managed node groups / Karpenter). Auto Mode is available in the target partitions; a managed fallback is only a contingency if the Auto Mode POC fails (see Requirement 3), not a maintained path.
- Optional PMP components not required by the certification exercise — Svix (webhooks), Maia (LLM assistant), PDF DocGen, and Marketplace — are excluded. Only PCLM plus the portal and build tooling are installed. Rationale: slide 22 of the certification exercise mandates only SCM/git, SSO (SAML/OIDC), CI/CD, and the end-to-end app lifecycle.
- Production HA tuning beyond what the demo and cert require (documented as future work).

### Research-informed design context

Decisions below are grounded in current first-party documentation. Key sources:
- EKS Auto Mode: https://docs.aws.amazon.com/eks/latest/best-practices/automode.html and https://docs.aws.amazon.com/eks/latest/userguide/automode.html
- Air-gapped / private EKS: https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html and https://aws.amazon.com/blogs/industries/deploy-infrastructure-for-telecom-workloads-in-an-air-gapped-aws-environment/
- EKS access entries (replaces aws-auth configmap): https://aws.amazon.com/blogs/containers/a-deep-dive-into-simplified-amazon-eks-access-management-controls/
- Terraform CI/CD on AWS: https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/create-a-ci-cd-pipeline-to-validate-terraform-configurations-by-using-aws-codepipeline.html
- PMP prerequisites: https://docs.mendix.com/private-mendix-platform/prerequisites/
- PMP Kubernetes-native CI/CD: https://docs.mendix.com/private-mendix-platform/configure-k8s/
- PMP air-gapped image migration (`installer init migrate`): https://docs.mendix.com/private-mendix-platform/quickstart/

Open questions to resolve in design (flagged, not yet decided):
- **Auto Mode air-gap behavior (POC-gated).** AWS's canonical private-cluster guide does not mention EKS Auto Mode. Auto Mode nodes reach EC2/ECR/STS/eks-auth over PrivateLink, so it is expected to work in an air-gapped VPC with the right endpoints, but this MUST be proven in a POC before commitment. Auto Mode is the single planned compute path (both target partitions offer it); a managed-node contingency is only invoked if the POC fails.
- **Dependency vendoring — decided direction: prestage artifacts in AWS ECR and S3, with parameterized source locations.** Required images, packages, installers, charts, and binaries are staged into in-account stores (ECR for images, S3 for files/installers, an internal Helm/OCI repo as needed). Mendix ships an official mechanism for this (`installer init migrate`). All source locations are Terraform inputs. Where a controlled egress exists, ECR pull-through cache may populate images on-demand; otherwise artifacts are pre-staged out-of-band. The remaining design detail is how the staging step is packaged/automated, not whether to consume from ECR/S3.
- **License is not a blocker.** Per the Mendix contact, no license is needed to install and test the platform; a trial license is cut once everything is standing. The demo build therefore does not gate on licensing.
- **SCM/CI-CD — decided: self-hosted GitLab in-cluster.** The Mendix partner contact confirmed a preference for GitLab, which is also on PMP's documented supported VCS provider list. GitLab provides VCS and CI/CD (GitLab CI with GitLab Runner on the Kubernetes executor) and supports offline/air-gapped installation. Design to decide how much of GitLab's stateful tier (PostgreSQL, object storage) reuses the module's existing RDS/S3 vs. runs in-cluster.
- **SSO IdP — decided: pluggable external OIDC/SAML, no specific IdP baked in.** The module accepts standard OIDC/SAML config inputs and provisions no IdP, so it is reusable against whatever IdP an environment already has. For the certification demo, the in-cluster GitLab acts as the OIDC provider (a deployment-time choice, verified capable via GitLab docs). Cognito and Keycloak are intentionally not designed around (YAGNI); any compliant IdP works via inputs. The upstream Terraform provides no IdP/SSO wiring, so this is net-new regardless. The cert brief names no specific IdP (only "SAML/OIDC").

## Glossary

- **PMP** — Private Mendix Platform. The self-hosted Mendix platform product delivered by certified partners.
- **Mx4PC / Mendix for Private Cloud** — The Mendix Operator-based foundation that runs Mendix apps on Kubernetes; PMP builds on it.
- **Mendix Operator** — Kubernetes operator that manages Mendix app environments (database provisioning, deployment).
- **PCLM** — Private Cloud License Manager; manages Mendix operator licenses per namespace.
- **MDA** — Mendix Deployment Archive; the build artifact produced from a Mendix project and deployed to the cluster.
- **mxbuild** — The Mendix build tooling that compiles a project into an MDA.
- **Studio Pro** — The Mendix low-code IDE where apps are modeled and committed to source control.
- **Connectivity profile** — The network state a deployment targets: `connected` (internet egress allowed) or `airgapped` (no internet egress; partition control plane reached via VPC endpoints). See Requirement 1.
- **Partition** — An AWS partition. The target partitions for this module are `aws` (commercial) and `aws-us-gov` (GovCloud); service, endpoint, AMI, and feature availability differ between them, so the module is written partition-neutrally and derives partition-specific values dynamically.
- **EKS Auto Mode** — AWS-managed EKS mode that provisions/manages nodes (Karpenter on Bottlerocket), networking, load balancing, and storage as core components. The single planned compute path.
- **NodePool / NodeClass** — Auto Mode CRDs for customizing node provisioning and node networking/placement.
- **Access entries** — The EKS API-based mechanism for granting IAM principals cluster access, replacing the `aws-auth` ConfigMap.
- **Pull-through cache** — ECR feature that lazily mirrors images from an upstream registry into ECR (usable where a controlled egress exists).
- **IRSA** — IAM Roles for Service Accounts; maps Kubernetes service accounts to IAM roles via OIDC.
- **OOTB** — Out-of-the-box; PMP's built-in Kubernetes-native CI/CD capability.
- **GitLab (self-hosted)** — The decided SCM and CI/CD platform, deployed in-cluster via the official cloud-native Helm chart; on PMP's supported VCS provider list and capable of offline/air-gapped installation.
- **GitLab CI / GitLab Runner** — GitLab's built-in pipeline engine and its runner; the Kubernetes executor runs each CI job as an on-demand pod in the cluster.
- **IdP (external/pluggable)** — The SSO identity provider is treated as an external dependency configured via OIDC/SAML inputs; the module provisions none. The demo uses the in-cluster GitLab as the OIDC provider, but any compliant IdP is interchangeable.
- **helmfile** — Declarative spec for deploying/upgrading sets of Helm releases; Mendix's documented PMP install mechanism.

---

## Requirements

### Requirement 1: Deployment connectivity profile, operator mode, and partition neutrality

**User Story:** As a platform engineer delivering into varied environments, I want one module that supports a connected-or-air-gapped network state and the appropriate Mendix operator registration mode, built partition-neutrally, so that the same codebase serves iteration in a connected account and air-gapped delivery in commercial and GovCloud partitions.

#### Acceptance Criteria
1. WHEN the module is configured THEN it SHALL expose a single documented `connectivity_profile` selector with two values: `connected` and `airgapped`.
2. WHEN `connected` is selected THEN outbound internet MAY be used (NAT/IGW permitted) to support learning and iteration.
3. WHEN `airgapped` is selected THEN no component SHALL require internet egress during installation or steady-state operation (jumphost excepted); the cluster SHALL reach only its own AWS partition's services via VPC endpoints, and all artifacts SHALL come from in-partition sources.
4. WHEN `airgapped` is selected THEN the EKS API server endpoint SHALL have private access enabled and public access disabled.
5. WHEN the module is configured THEN it SHALL expose a separate `operator_mode` variable with values `connected` and `standalone`, controlling whether `mxpc-cli` registers the cluster with the Mendix portal (`--clusterMode connected`) or operates without portal registration (`--clusterMode standalone`).
6. WHEN `operator_mode` is `connected` THEN the module SHALL accept and pass `namespace_id` and `namespace_secret` to the installer (upstream pattern). WHEN `operator_mode` is `standalone` THEN those values SHALL be optional and the installer SHALL omit them from all `mxpc-cli` invocations (current `dev/pmp` pattern).
7. WHEN the connectivity profile is `airgapped` THEN `operator_mode` SHALL be forced to `standalone` (the Mendix portal is unreachable), and the module SHALL emit a validation error if `operator_mode = connected` is explicitly set with the `airgapped` profile.
8. WHEN the module runs in either target partition (`aws`, `aws-us-gov`) THEN it SHALL NOT hardcode commercial ARNs, service endpoints, DNS suffixes, or AMI owners, and SHALL derive partition-specific values dynamically.
9. WHERE a feature is unavailable in the target partition THE design SHALL document the gap and select the partition-appropriate alternative rather than failing silently.
10. WHEN a deployment completes in `airgapped` mode THEN a documented verification step SHALL confirm no component reaches the public internet during steady-state operation.

### Requirement 2: Provide an explicit VPC / networking module

**User Story:** As a platform engineer, I want the module to either create the VPC and subnets it needs or consume an existing VPC, so that I can stand up a complete greenfield environment for the certification while still supporting environments (like the original `dev/pmp` target) where networking already exists.

#### Acceptance Criteria
1. WHEN a `create_vpc` flag is true (or no existing VPC is supplied) THEN the module SHALL create a VPC spanning at least three Availability Zones with private subnets sized and tagged for EKS.
2. WHEN `create_vpc` is false (existing VPC supplied) THEN the module SHALL consume the provided `vpc_id` and subnet IDs without creating new networking, preserving the current `dev/pmp` behavior.
3. WHEN the module is applied THEN exactly one of the two paths SHALL be active, and providing conflicting inputs (e.g., `create_vpc = true` plus an existing `vpc_id`) SHALL produce a clear validation error.
4. WHEN subnets are created THEN they SHALL carry the Kubernetes/EKS discovery tags required for load balancer and Auto Mode subnet selection.
5. WHEN the connectivity profile is `connected` THEN the created VPC MAY provision NAT/IGW for outbound access.
6. WHEN the connectivity profile is `airgapped` THEN the created VPC SHALL provision private subnets and the necessary VPC endpoints (at minimum: ECR API, ECR DKR, S3 gateway, EC2, STS, CloudWatch Logs, Elastic Load Balancing, SSM, SSMMessages, EC2Messages, `aps` and `aps-workspaces` (AWS Managed Service for Prometheus), and the endpoints EKS Auto Mode requires such as `eks` and `eks-auth`) and SHALL omit NAT gateways and internet gateways by default.
7. WHEN the VPC is created THEN DNS hostnames and DNS support SHALL be enabled (required for EKS private endpoint resolution).
8. WHEN an existing VPC is consumed in the `airgapped` profile THEN the module SHALL document (and where possible validate) the VPC endpoints and tags the existing VPC must already provide.
9. WHEN an ingress/routing layer is deployed THEN the module SHALL use classic Kubernetes `Ingress` (Mendix `endpoint.type = ingress`) fronted by an Application Load Balancer with an internal (non-internet-facing) scheme for the `airgapped` profile, using EKS Auto Mode's built-in ALB `IngressClass` (no controller to install). The `dev/pmp` branch currently disables NGINX ingress entirely (upstream `nginx-values.yaml` sets `scheme: internet-facing`); the modernized module SHALL remove the NGINX dependency in favor of the AWS-native ALB path. Gateway API is explicitly out of scope for this iteration (Auto Mode's built-in controller does not support it, and it would add an unused self-managed component); it MAY be revisited as a future enhancement.

### Requirement 3: Modernize the EKS cluster to a low-operations posture

**User Story:** As a platform engineer delivering PMP, I want the EKS cluster built on current modules and EKS Auto Mode, so that node management, scaling, load balancing, and storage are handled by AWS and I can demonstrate a modern, low-ops platform.

#### Acceptance Criteria
1. WHEN the module provisions an EKS cluster THEN it SHALL use `terraform-aws-eks` v20 or later (or an equivalent current source) instead of the pinned v19.21.0 commit.
2. WHEN the cluster is created THEN the module SHALL enable EKS Auto Mode for compute and SHALL NOT define fixed-size managed node groups for the default workload pool.
3. WHERE workloads require specific instance characteristics THE module SHALL allow customization via Auto Mode NodePools/NodeClasses without reintroducing manually managed node groups.
4. WHEN cluster access is configured THEN the module SHALL use EKS access entries (authentication mode `API` or `API_AND_CONFIG_MAP`) instead of managing the `aws-auth` ConfigMap.
5. WHEN Auto Mode is enabled THEN the cluster IAM role SHALL include the additional permissions Auto Mode requires, including the permissions needed to manage any custom (non-`eks-cluster-sg-*`) security groups the module attaches.
6. WHEN the EKS control-plane version is configurable THEN the default SHALL be a currently supported Kubernetes version, and the variable SHALL be documented as a customer-owned upgrade responsibility.
7. WHEN Auto Mode is enabled THEN the module SHALL remove or disable the now-redundant resources it supersedes (EBS CSI driver IRSA, AWS Load Balancer Controller, cluster autoscaler) and document the change.
8. IF the design-phase POC (see design §4) proves Auto Mode cannot operate in the target air-gapped configuration, THEN a managed-node-group + Karpenter contingency SHALL be introduced and documented; this is documentation-only and not built unless the POC fails.
9. WHEN the modernized module is applied THEN `terraform validate`, `tflint`, and `tfsec`/equivalent SHALL pass with no new high-severity findings introduced by these changes.
10. WHERE FIPS-validated node cryptography is required THE module SHALL support optionally enabling it on EKS Auto Mode via the Auto Mode node FIPS setting (`advancedSecurity.fips` on a custom NodeClass), defaulting to OFF for the demo; Auto Mode's FIPS option provides FIPS 140-2 validated modules and is available in GovCloud.

### Requirement 4: SSO / OIDC identity integration

**User Story:** As a partner, I want PMP and cluster access secured with SSO (SAML/OIDC) via a pluggable, external identity provider, so that I meet the certification's SSO requirement and can reuse this module against whatever IdP a future environment already has — without the module depending on any specific one.

#### Acceptance Criteria
1. WHEN PMP is installed THEN an IdP for SSO SHALL be available and configurable during installation (OIDC or SAML), per PMP prerequisites.
2. WHEN the module wires SSO THEN it SHALL treat the IdP as an external, pluggable dependency: it accepts standard configuration inputs (OIDC discovery/issuer URL, client ID/secret, scopes, and claim→role mappings; or SAML metadata) and SHALL NOT provision or hard-depend on any specific IdP product.
3. WHEN any OIDC/SAML-compliant IdP is supplied THEN it SHALL be usable by changing inputs only, with no code changes (customer-provided IdP, an in-cluster GitLab acting as OIDC provider, or any other compliant provider are interchangeable).
4. WHEN client credentials are provided THEN the client secret SHALL be sourced from AWS Secrets Manager and SHALL NOT appear in plaintext outputs or state where avoidable.
5. WHEN EKS cluster access is granted to human operators THEN it SHALL be mapped through federated identity to EKS access entries / access policies rather than static IAM users.
6. WHEN SSO is configured THEN the documentation SHALL describe the client/application registration, redirect URIs, and group→role mapping needed for the demo, using the demo's chosen IdP as the worked example.

### Requirement 5: Vendor and mirror external dependencies for the air-gapped profile

**User Story:** As a certified partner deploying into an air-gapped environment, I want every external dependency vendored into in-partition ECR/S3, so that neither installation nor steady-state operation needs internet access.

#### Acceptance Criteria
1. WHEN the air-gapped path is built THEN the solution SHALL enumerate every external dependency it pulls today, including (at minimum): Terraform providers and remote modules; the `mxpc-cli` binary and any `wget`-fetched files (e.g., the RDS CA bundle from `truststore.pki.rds.amazonaws.com`); the PMP/Mx4PC and `pmp-pipeline-tools` container images; the Mendix registry images from `private-cloud.registry.mendix.com`; Helm charts; GitLab images/charts; observability images/charts; and the mxbuild package.
2. WHEN images are staged THEN the solution SHALL use Mendix's official image-migration mechanism (`installer init migrate`) where applicable, and ECR pull-through cache where a controlled egress exists, populating in-partition ECR/S3.
3. WHEN the profile is `airgapped` THEN the deployment SHALL consume dependencies only from in-partition sources (ECR, S3, an internal Helm/OCI repository, or a Terraform network/filesystem mirror) and SHALL NOT execute any `wget`/`curl`/registry pull that targets a public internet endpoint.
4. WHEN the packaging of the staging step is chosen THEN the design SHALL decide between (and document the tradeoffs of) options such as: a helper script/job that populates ECR/S3, or a checked-in `vendor/` manifest driving the same. The runtime consumption model (pull from ECR/S3/internal repos) is decided; only the staging/packaging mechanism remains a design detail.
5. WHEN dependency versions are pinned THEN they SHALL be recorded (lockfiles, digests, or an explicit manifest) so the staged bundle is reproducible and auditable.
6. WHERE a dependency must call an AWS regional/partition API THE design SHALL document the required VPC endpoint instead of treating it as an internet dependency, consistent with Requirement 2.
7. WHEN artifact source locations are configured THEN every source (ECR repository/registry, S3 bucket/prefix, Helm/OCI repo URL) SHALL be a Terraform input with sensible defaults, so an environment can point the module at its own stores without code changes.
8. WHEN the solution is delivered THEN it SHALL document the complete list of artifacts that must be staged and their expected locations, so the dependency can be called out during the presentation and satisfied per PMP's air-gapped guidance.

### Requirement 6: Secrets and configuration management

**User Story:** As a partner, I want platform secrets managed securely, so that no credentials are exposed in state, logs, or outputs and the deployment meets enterprise security expectations.

#### Acceptance Criteria
1. WHEN secrets (database passwords, Grafana admin, namespace secrets, IdP client secrets) are created THEN they SHALL be stored in AWS Secrets Manager and SHALL NOT be exposed as plaintext Terraform outputs.
2. WHEN resources are encrypted at rest THEN EBS, RDS, S3, and Secrets Manager SHALL use KMS encryption; customer-managed keys SHALL be supported (via the existing `kms_key_admin_arns_list` / `kms_key_user_arns_list` inputs) but AWS-managed keys are an acceptable default to keep the demo simple.
3. WHEN PMP reads its own credentials (VCS PATs, build cluster token, Grafana API key, MDA/registry keys) THEN it SHALL read them directly from AWS Secrets Manager using IRSA, with secrets named under a documented prefix (e.g. `PMP-*`), and the IAM policy granting `secretsmanager:GetSecretValue` / `secretsmanager:DescribeSecret` SHALL be partition-neutral (the ARN partition SHALL be derived dynamically, not hardcoded to `aws`). The Secrets Store CSI Driver is NOT required for PMP's own credentials.
4. WHEN sensitive values are passed to Helm THEN they SHALL be marked sensitive and SHALL NOT appear in plan output or logs.
5. WHEN the Mendix operator's database/storage-plan secrets are provisioned THEN they SHALL follow a separate path from PMP's own credentials, entered at install time for the demo; the Secrets Store CSI Driver is optional and SHALL NOT be used for the demo.

### Requirement 7: PMP install/upgrade layer on top of the foundation

**User Story:** As a partner operating PMP as a managed service, I want the Private Mendix Platform itself installed and upgraded as a distinct layer on top of the Terraform-provisioned foundation, so that I can apply PMP's recurring product updates without re-running infrastructure provisioning.

#### Acceptance Criteria
1. WHEN the platform is delivered THEN the boundary SHALL be explicit across three tiers: (a) Terraform provisions the AWS substrate plus the Mx4PC operator foundation; (b) a helmfile layer, run through the pipeline, installs PMP (PCLM, portal, build tooling) on top; and (c) PMP's own platform configuration — CI/CD build settings, VCS host, observability wiring, and Kubernetes cluster registration — is performed in the PMP admin panel (GUI) and captured as a documented runbook step, NOT automated as config-as-code (no supported API exists for it; automating it is out of scope as speculative — YAGNI).
2. WHEN PMP is installed THEN it SHALL use Mendix's documented install mechanism (helmfile and `mx-pclm-cli`) rather than being reimplemented in Terraform.
3. WHEN PMP must be updated THEN the install layer SHALL support repeatable, declarative re-apply (matching PMP's regular release cadence) without requiring a `terraform apply`.
4. WHEN the install layer is operated THEN the installation and upgrade of PMP SHALL be runnable through the CI/CD pipeline (Requirement 10) so installs and upgrades are automated, reviewed, and auditable, WHILE PMP's own platform configuration (tier (c) of 7.1) SHALL remain a documented manual admin-panel step rather than a pipeline-automated config-as-code step.
5. WHERE the profile is `airgapped` THE PMP install layer SHALL source all charts, images, and binaries from the vendored in-partition sources defined in Requirement 5.
6. WHEN the layering decision is documented THEN it SHALL state whether the Mx4PC operator bootstrap remains in Terraform (current `helm_release` pattern) or also moves to the pipeline, with the rationale.
7. WHEN PMP is installed and tested for the demo THEN the workflow SHALL NOT require a production license; per Mendix guidance a trial license is applied after the platform is standing, so the build and lifecycle demo do not gate on licensing.
8. WHEN PCLM is installed THEN it SHALL require Mendix Operator version 2.21.0 or later and SHALL use a dedicated PostgreSQL database; a separate database/role on the shared RDS instance is acceptable for the demo.

### Requirement 8: Enable the Mendix application build & deploy lifecycle

**User Story:** As a partner demonstrating PMP, I want a working end-to-end app pipeline from Studio Pro commit through build to deployment in the target cluster, so that I can show the full development lifecycle required by the certification.

#### Acceptance Criteria
1. WHEN PMP is configured for CI/CD THEN the module SHALL support the PMP out-of-the-box Kubernetes-native build option as the default path.
2. WHEN the Kubernetes-native CI/CD is enabled THEN the module SHALL create the required build namespace, CICD service account, role, and role binding granting `pods` and `pods/log` permissions (`create`, `get`, `delete`).
3. WHEN PMP must call the cluster API server THEN the module SHALL make the cluster CA certificate available for configuration in the Mendix operator configuration (`customCASecretName`) of the PMP namespace.
4. WHEN MDA build artifacts are produced THEN the module SHALL provide S3-compatible storage for MDA files and the IAM access required for the build pod to read/write them.
5. WHEN an app is deployed THEN the configuration SHALL support deploying to another namespace in the same (or another) cluster, matching the certification's deployment requirement.
6. WHERE the profile is `airgapped` THE build tooling image (`pmp-pipeline-tools`) and the mxbuild package source SHALL be served from in-partition sources (ECR / S3) per Requirement 5.
7. WHEN the lifecycle is exercised THEN it SHALL be possible to create a new sample project in the in-cluster GitLab, commit a change, build the MDA, and deploy it, with the steps documented for the demo.
8. WHEN the PMP Kubernetes-native CI/CD, build cluster, build images, and MDA storage settings are set THEN they SHALL be configured through the PMP admin panel and captured as a documented runbook step, consistent with the platform-configuration boundary in Requirement 7.

### Requirement 9: Observability stack compatible with PMP

**User Story:** As a partner operating the platform, I want a monitoring and logging stack that PMP can integrate with, so that the platform UI can surface app logs and metrics and I can demonstrate day-2 ops.

#### Acceptance Criteria
1. WHEN observability is deployed THEN it SHALL provide AWS Managed Service for Prometheus (AMP) (metrics), Loki (logs), and Grafana (visualization), compatible with the versions PMP currently validates.
2. WHEN PMP integrates with Grafana THEN the configuration SHALL use a single Loki data source and a single Prometheus data source (PMP does not support multiple of either).
3. WHEN Grafana is exposed THEN it SHALL provide the API endpoints PMP requires (`/api/health`, `/api/datasources`, datasource proxy, Loki `query_range`, Prometheus labels/values, and `/api/ds/query`).
4. WHEN metrics are provisioned THEN they SHALL use AWS Managed Service for Prometheus (AMP) as the metrics backend in both target partitions (`aws` and `aws-us-gov`). WHERE the profile is `airgapped` THE cluster SHALL reach AMP over the `aps` and `aps-workspaces` VPC interface endpoints (ADOT remote_write and Grafana queries) with no internet egress.
5. WHERE the profile is `airgapped` THE observability components SHALL be installed from in-partition chart/image sources per Requirement 5 (Grafana, Loki, and ADOT charts and images come from in-partition ECR/S3 sources), while AMP itself is reached via the `aps` and `aps-workspaces` VPC interface endpoints.
6. WHEN observability is provisioned THEN administrative credentials SHALL be stored in AWS Secrets Manager rather than rendered in plaintext outputs.

### Requirement 10: CI/CD pipeline for infrastructure, PMP, and app delivery

**User Story:** As a partner operating the platform as a managed service, I want a git-driven pipeline that validates and applies Terraform changes, runs the PMP install layer, and supports app delivery, so that updates are automated, reviewed, and auditable without depending on the public internet — and reusable across future engagements.

#### Acceptance Criteria
1. WHEN infrastructure code is hosted in source control THEN it SHALL use self-hosted GitLab deployed in-cluster (the decided SCM, on PMP's supported VCS provider list), satisfying the certification's SCM requirement without depending on github.com.
2. WHEN GitLab is deployed THEN it SHALL be installed via its official cloud-native Helm chart, and the design SHALL decide which stateful components (PostgreSQL, object storage, container registry) reuse the module's RDS/S3/ECR versus run in-cluster, per GitLab's reference architecture.
3. WHEN pipelines run THEN they SHALL use GitLab CI with GitLab Runner on the Kubernetes executor, so CI jobs run as on-demand pods inside the cluster.
4. WHEN a change is pushed to the configured branch THEN the pipeline SHALL execute, at minimum, a validate stage, a plan stage, a manual approval, and an apply stage.
5. WHEN the validate stage runs THEN it SHALL execute `terraform fmt -check`, `terraform validate`, and security/policy scanning (e.g., `tflint`, `tfsec`/`checkov`), and SHALL fail the pipeline on high-severity findings.
6. WHEN Terraform runs in the pipeline THEN it SHALL use a remote state backend (S3 with state locking) encrypted with KMS, consistent with the module's existing backend guidance.
7. WHEN the plan stage completes THEN the plan output SHALL be retained as a pipeline artifact and surfaced for the approver before apply.
8. WHEN the PMP install layer (Requirement 7) is run THEN the pipeline SHALL be able to execute it as a distinct stage separate from infrastructure apply.
9. WHERE the profile is `airgapped` THE GitLab install, runners, and build jobs SHALL obtain GitLab images/charts, Terraform providers, modules, and tool images from in-partition sources per Requirement 5 rather than the public internet, using GitLab's offline/air-gapped install approach.
10. WHEN the pipeline executes THEN its execution identity (IAM role or runner service account) SHALL follow least privilege, scoped to the resources it manages.

### Requirement 11: Backward compatibility and migration

**User Story:** As the maintainer of this module, I want the modernization to be adoptable from the current `dev/pmp` state, so that I do not have to throw away working customizations and can migrate deliberately.

#### Acceptance Criteria
1. WHEN the modernization is delivered THEN it SHALL preserve the existing customizations on `dev/pmp` that remain relevant (internal load balancer, restricted cluster endpoint access, multiple cluster admin roles) or document why each is superseded.
2. WHEN breaking changes are introduced (EKS module upgrade, access entries, Auto Mode) THEN a migration note SHALL document the required steps and any resource replacement/state moves.
3. WHEN the work is structured THEN it SHALL be developed on a dedicated branch off `dev/pmp` and SHALL keep `connected`-profile deployment working for iterative learning.
4. WHEN variables change THEN the module SHALL avoid silent behavioral changes — renamed/removed variables SHALL be documented in the README and migration note.

### Requirement 12: Certification documentation & demo artifacts

**User Story:** As a partner preparing for the certification interview, I want documentation and a concise architecture overview, so that two engineers can independently present and answer questions about the air-gapped solution.

#### Acceptance Criteria
1. WHEN the work is complete THEN the README and deployment guide SHALL be updated to reflect the connectivity profiles, Auto Mode, networking, CI/CD, SSO, vendoring, and the PMP install layer.
2. WHEN preparing the presentation THEN there SHALL be a concise architecture overview (diagram + narrative) covering Mendix, PMP, and the demo AWS architecture suitable for a customer kickoff.
3. WHEN the deployment is demonstrated THEN there SHALL be a step-by-step runbook covering deploy, app lifecycle (create → commit → build → deploy), and common day-2 operations.
4. WHEN reflection is required by the exercise THEN documentation SHALL capture deployment experience notes, automation/IaC improvements adopted, and suggested PMP improvements.
5. WHERE assumptions were made beyond the provided background THE documentation SHALL list them explicitly, as the exercise instructs.
