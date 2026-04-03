# Gazebo Ignition Fortress on OVHcloud

Terraform project to provision an OVHcloud GPU instance running Gazebo Ignition Fortress, ROS2 Humble, and NoMachine for remote desktop access.

## Stack

- **Cloud**: OVHcloud Public Cloud (GRA11), GPU flavor `l4-90`
- **OS**: Ubuntu 22.04
- **Simulation**: Gazebo Ignition Fortress + Ignition-ROS2 bridge
- **Remote desktop**: XFCE + NoMachine (port 4000)
- **IaC**: Terraform (OVH + OpenStack providers)
- **CI/CD**: Jenkins pipeline

## Documentation

See [docs/USER_MANUAL.md](docs/USER_MANUAL.md) for full instructions on:

- Prerequisites (OVH API credentials, SSH keys)
- Manual provisioning step by step
- Jenkins pipeline setup and usage
- Known issues and fixes
