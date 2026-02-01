# Gazebo ignition fortress deployed to OVHcloud
Terraform project to create an ovhcloud instance with a GPU to execute simulations with Gazebo ignition fortress

# Manual settings to use Nomachine

## Sur le mac

``` 
> scp /Users/scrumconseil/.ssh/id_ed25519_nomachine.pub ubuntu@IP_ADDRESS_GEZABO_SERVER:/home/ubuntu/.ssh/id_ed25519_nomachine_client.pub
```

## Sur le serveur
```
> mkdir -p /home/ubuntu/.nx/config
> cat /home/ubuntu/.ssh/id_ed25519_nomachine_client.pub >> /home/ubuntu/.nx/config/authorized.crt
> chmod 0600 /home/ubuntu/.nx/config/authorized.crt
```
