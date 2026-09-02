# demo-react-python-service

Take-home submission: an architecture & migration proposal for re-platforming
this app's infrastructure, plus a small hands-on demo of one piece of it.

- **Architecture & migration proposal:** [`docs/arch-migration-proposal.md`](docs/arch-migration-proposal.md)
  (includes the system diagram)
- **Hands-on demo:** Terraform, in [`terraform/`](terraform/) — an ECS
  Fargate service with autoscaling, the "basic service with auto-scaling
  capabilities" piece from the assignment
- **Also included, illustrative only:** a GitHub Actions workflow at
  [`.github/workflows/build-deploy.yml`](.github/workflows/build-deploy.yml)
  showing the CI/CD pattern from the proposal doc, see below for why it won't
  actually run in this repo

## Running the Terraform demo

**Requirements:** Terraform >= 1.15, an AWS account with credentials
configured locally (`aws configure` or equivalent), and the AWS provider will
resolve to `hashicorp/aws` ~> 6.0.

```bash
cd terraform/dev
terraform init
terraform plan
terraform apply
```

This provisions, in your AWS account's **default VPC**:

- An ECS cluster and a Fargate service running a placeholder `nginx` container
- An Application Auto Scaling target + target-tracking policy on the
  service's CPU utilization (min 1 / max 4 tasks, target 60%)
- A CloudWatch log group, a security group, and the IAM execution role
  Fargate needs to pull the image and ship logs

Tear it down when you're done:

```bash
terraform destroy
```

Module lives in `terraform/modules/ecs-service/`, the `terraform/dev/`
directory is the root config that calls it, matching the `modules/` +
per-environment root layout described in the proposal doc's Infrastructure as
Code section.

### Verifying it works

There's no ALB in this demo (kept deliberately basic, see Assumptions and
shortcuts below), so the running task gets a public IP directly, that's
what you hit to check it's up. In the AWS Console: ECS → Clusters →
`demo-app-cluster` → the `demo-app` service → Tasks tab → click the running
task → the **Public IP** is listed under the task's network details. Grab
that IP and:

```bash
curl http://<public-ip>
```

Should return nginx's default welcome page. Tested against a real apply,
confirmed working.

## About the GitHub Actions workflow

`.github/workflows/build-deploy.yml` shows the CI/CD pattern from the
proposal doc: test/build on PR, build/push/deploy on merge to `main`, using
the same cluster/service names as the Terraform demo above. **It will not
run successfully as-is** — this repo has no application code, so there's no
Dockerfile to build and no `AWS_ROLE_ARN` secret configured. It's here to
show the shape of the pipeline, not as a working pipeline. The pattern
itself isn't hypothetical: it's adapted from a workflow of the same shape
I run in production on another project.

The assignment asks for one (1) hands-on area; Terraform IaC above is that
submission. This workflow is extra, included to show the CI/CD design from
the doc a bit more concretely.

## Assumptions and shortcuts

- **Default VPC, not the proposal's private-subnet design.** The proposal
  calls for tasks in private subnets behind an ALB, with a NAT Gateway for
  fixed outbound IPs. This demo uses the account's default VPC (public
  subnets only) and gives the task a public IP directly, no ALB, no NAT
  Gateway, no private subnet. That's a simplification for the demo, not a
  change to the actual design in the proposal doc.
- **Local Terraform state**, not the S3 remote state described in the
  proposal. Remote state needs a pre-existing bucket someone would have to
  bootstrap first; not worth the setup friction for a demo meant to be
  cloned and run directly.
- **Placeholder `nginx` image**, since there's no real application in this
  repo. The point of the demo is the ECS-service-with-autoscaling pattern,
  not a specific app.
- **One generic service, not the dispatcher.** This provisions the general
  "standing ECS service with autoscaling" pattern the proposal's dispatcher
  service would eventually run on, not the dispatcher's actual logic (SQS,
  poll loop, per-job `RunTask` calls).
- **No ALB**, kept deliberately basic per the assignment's "basic service
  with auto-scaling capabilities" wording.

## What I'd do next with more time

- Wire the Terraform demo's cluster/service names into the GitHub Actions
  workflow's actual deploy path against a real, minimal app so the pipeline
  runs end-to-end instead of being illustrative.
- Move state to S3 with native locking (Terraform 1.10+), matching the
  proposal doc, and bootstrap that backend as its own small config.
- Add the dispatcher-specific pieces (SQS queue, poll loop, per-job task
  definition) as a second module, building out the actual dispatcher
  architecture rather than the generic scaled-service pattern.
- Add a `dev`/`prod` split using the module twice with different variables,
  to actually demonstrate the per-environment structure described in the
  doc rather than just having the one environment.

## AI Assistance Policy

**Tools used:** Claude Code, throughout.

**What it helped with:**
- Grammar and clarity passes on the architecture proposal doc, and general
  idea-bouncing/discussion while working through design decisions (ECS vs.
  Kubernetes, dispatcher design, database scalability approach, etc.) — the
  architectural reasoning and decisions themselves are mine.
- Generated the Mermaid system diagram, from a description of the
  architecture I gave it.
- Generated the Terraform boilerplate in `terraform/` from a description of
  what I wanted (module/root layout, default VPC, ECS service + autoscaling,
  no ALB), and the GitHub Actions workflow, adapted from a pattern I already
  use in production on a personal project, with names/values changed to
  match this repo.

**Verification:** I read through all generated files (docs and code). For
the Terraform, I ran `terraform validate`, then `apply`'d it against my own
AWS account to confirm it actually provisions a working ECS service with
autoscaling, and `destroy`'d it afterward. The GitHub Actions pattern is one
I already know works, since I run the same shape of workflow in production
elsewhere.

**Exclusions:** no AI output was submitted without being reviewed first.
