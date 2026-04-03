# Gazebo Fortress on OVHcloud — User Manual

This guide explains how to provision and destroy a GPU instance running Gazebo Ignition Fortress on OVHcloud, either manually or via Jenkins.

---

## Prerequisites

### OVH API credentials

You need four OVH API credentials. Generate them at https://www.ovh.com/auth/api/createToken:

| Variable | Description |
|---|---|
| `application_key` | OVH application key |
| `application_secret` | OVH application secret |
| `consumer_key` | OVH consumer key |
| `project_id` | OVH Public Cloud project ID (found in OVH Control Panel → Public Cloud → project name) |

### SSH keys

Two SSH key pairs are required:

- **`id_ed25519`** — used to SSH into the provisioned instance
- **`id_ed25519_nomachine`** — used by NoMachine for remote desktop authentication

Place the `.pub` files at the root of this repository before running Terraform.

To generate them if needed:
```bash
ssh-keygen -t ed25519 -f id_ed25519 -C "your@email.com"
ssh-keygen -t ed25519 -f id_ed25519_nomachine -C "nomachine"
```

> Keep the private keys (`id_ed25519`, `id_ed25519_nomachine`) secret and never commit them.

---

## Manual provisioning

### 1. Install Terraform

```bash
# macOS
brew install terraform

# Verify
terraform version
```

### 2. Configure credentials

Export your OVH credentials and OpenStack credentials as environment variables:

```bash
export TF_VAR_project_id_var=<your_project_id>
export TF_VAR_application_key_var=<your_application_key>
export TF_VAR_application_secret_var=<your_application_secret>
export TF_VAR_consumer_key_var=<your_consumer_key>

export OS_AUTH_URL=https://auth.cloud.ovh.net/v3
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_TENANT_ID=<your_tenant_id>
export OS_TENANT_NAME=<your_tenant_name>
export OS_USERNAME=<your_openstack_username>
export OS_PASSWORD=<your_openstack_password>
export OS_REGION_NAME=GRA11
```

> These values can be found in the OpenStack RC file downloadable from OVH Control Panel → Public Cloud → Users & Roles.

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Plan

```bash
terraform plan -out tfplan
terraform show -no-color tfplan   # review before applying
```

### 5. Apply

```bash
terraform apply tfplan
```

Terraform will:
- Upload the SSH public key to OVH
- Create the private network, subnet, and gateway
- Reserve a floating (public) IP
- Provision a GPU instance (flavor `l4-90`) with Ubuntu 22.04
- Automatically install: NVIDIA drivers, Gazebo Fortress, XFCE, NoMachine, ROS2 Humble, and the Ignition-ROS2 bridge

The instance takes approximately **10-15 minutes** to fully initialize (cloud-init runs on first boot).

### 6. Connect via SSH

```bash
ssh -i id_ed25519 ubuntu@<floating_ip>
```

The floating IP is displayed in the Terraform output:
```bash
terraform output floating_ip_address
```

### 7. Connect via NoMachine

1. Install NoMachine on your local machine: https://www.nomachine.com/download
2. Create a new connection to `<floating_ip>` on port `4000`
3. Use SSH key authentication with `id_ed25519_nomachine`

### 8. Destroy

```bash
terraform destroy
```

> The floating IP has `prevent_destroy = true` to avoid losing a reserved public IP accidentally. To destroy it, remove that lifecycle rule first.

---

## Jenkins provisioning

### Jenkins setup

#### Required credentials

Add the following credentials in Jenkins (Manage Jenkins → Credentials → Global):

| Credential ID | Type | Description |
|---|---|---|
| `TF_VAR_project_id_var` | Secret text | OVH project ID |
| `TF_VAR_application_key_var` | Secret text | OVH application key |
| `TF_VAR_application_secret_var` | Secret text | OVH application secret |
| `TF_VAR_consumer_key_var` | Secret text | OVH consumer key |
| `OS_USERNAME` | Secret text | OpenStack username |
| `OS_PASSWORD` | Secret text | OpenStack password |
| `OS_TENANT_ID` | Secret text | OpenStack tenant ID |
| `OS_TENANT_NAME` | Secret text | OpenStack tenant name |
| `gazebo_ssh_key` | SSH Username with private key | Private key of `id_ed25519` |

#### Required tools on the Jenkins agent

- `terraform` in PATH
- `ssh` and `scp` available

### Running the pipeline

#### Provision (Apply)

1. Trigger the pipeline manually in Jenkins
2. Set parameters:
   - `action` → `apply`
   - `autoApprove` → `true` to skip manual approval, `false` to review the plan first
   - `IP_ADDRESS_GAZEBO_SERVER` → leave as `127.0.0.1` (will be overridden by Terraform output after first apply)
3. Run

When `autoApprove` is `false`, the pipeline stops after the plan stage. Review `tfplan.txt` in the build artifacts, then re-run with `autoApprove = true` to apply.

#### Destroy

1. Trigger the pipeline
2. Set parameters:
   - `action` → `destroy`
   - `autoApprove` → `true`
3. Run

### Known issues

#### SSH key already exists (409 Conflict)

If the pipeline fails with `Key pair 'gazebo_key_ed25519' already exists`, the key exists in OVH but not in Terraform state (e.g. after a state reset).

Fix: delete the key manually in OVH Control Panel → Public Cloud → SSH Keys, then re-run the pipeline.

#### State file permission denied

If `terraform import` or `terraform apply` fails with `permission denied` on `terraform.tfstate`, run commands as the Jenkins user:

```bash
sudo -u jenkins terraform ...
```

---

## Architecture overview

```
OVHcloud Public Cloud (GRA11)
├── Floating IP (public, persistent)
├── Private Network + Subnet (192.168.1.0/24)
├── Gateway (model: s)
└── GPU Instance (l4-90, Ubuntu 22.04)
    ├── NVIDIA drivers
    ├── Gazebo Ignition Fortress
    ├── ROS2 Humble + Ignition-ROS2 bridge
    ├── XFCE desktop
    └── NoMachine (port 4000)
```

### Open ports

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 4000 | TCP | NoMachine |
| 8092 | TCP | Custom application |
| 11345 | TCP/UDP | Ignition Transport discovery |
| 11346–11355 | TCP/UDP | Ignition Transport communication |
