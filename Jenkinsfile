pipeline {
    agent any

    parameters {
        booleanParam(name: 'autoApprove', defaultValue: false, description: 'Automatically run apply after generating plan?')
        choice(name: 'action', choices: ['apply', 'destroy'], description: 'Select the action to perform')
    }
    
    options {
        // Keep builds for 30 days
        buildDiscarder(logRotator(daysToKeepStr: '30'))
        // Timeout after 2 hours
        timeout(time: 2, unit: 'HOURS')
        // Disable concurrent builds
        disableConcurrentBuilds()
        // Enable timestamps in console output
        timestamps()
    }

    environment {
        // Git configuration
        GIT_DEPTH = '0'

        // OVH/Terraform API credentials
        TF_VAR_project_id_var = credentials('TF_VAR_project_id_var')
        TF_VAR_application_secret_var = credentials('TF_VAR_application_secret_var')
        TF_VAR_consumer_key_var = credentials('TF_VAR_consumer_key_var')
        TF_VAR_application_key_var = credentials('TF_VAR_application_key_var')

        // OpenStack credentials (sensitive)
        OS_USERNAME = credentials('OS_USERNAME')
        OS_PASSWORD = credentials('OS_PASSWORD')
        OS_TENANT_ID = credentials('OS_TENANT_ID')

        // OpenStack configuration (non-sensitive)
        OS_AUTH_URL = 'https://auth.cloud.ovh.net/v3'
        OS_IDENTITY_API_VERSION = '3'
        OS_USER_DOMAIN_NAME = 'Default'
        OS_PROJECT_DOMAIN_NAME = 'Default'
        OS_TENANT_NAME = '9376721598096746'
        OS_REGION_NAME = 'GRA11'

        // IP_ADDRESS_GAZEBO_SERVER
        IP_ADDRESS_SERVER = params.IP_ADDRESS_GAZEBO_SERVER
    }

    stages {

        stage('Terraform init') {
            steps {
                script {
                    sh '''
                        terraform init
                    '''
                }
            }
        }

        stage('Plan') {
            when {
                expression { params.autoApprove == false }
            }
            steps {
                script {
                    sh '''
                        terraform plan -out tfplan
                        terraform show -no-color tfplan > tfplan.txt
                    '''
                }
            }
        }

        stage('Apply auto-approve') {
            when {
                expression { params.autoApprove && params.action == "apply"}
            }
            steps {
                sh """
                    terraform apply \
                        -target=ovh_cloud_project_network_private.private_net \
                        -target=ovh_cloud_project_network_private_subnet.private_subnet \
                        -target=ovh_cloud_project_gateway.gateway \
                        -target=ovh_cloud_project_instance.gazebo_instance --auto-approve
                    terraform apply -auto-approve
                    scp id_ed25519_nomachine.pub ubuntu@$IP_ADDRESS_SERVER:/home/ubuntu/.ssh/id_ed25519_nomachine_client.pub
                    ssh ubuntu@$IP_ADDRESS_SERVER 'mkdir -p /home/ubuntu/.nx/config'
                    ssh ubuntu@$IP_ADDRESS_SERVER 'cat /home/ubuntu/.ssh/id_ed25519_nomachine_client.pub >> /home/ubuntu/.nx/config/authorized.crt'
                    ssh ubuntu@$IP_ADDRESS_SERVER 'chmod 0600 /home/ubuntu/.nx/config/authorized.crt'
                """
            }
        }

        stage('Apply !auto-approve') {
            when {
                expression { params.autoApprove == false && params.action == "apply" }
            }
            steps {
                sh 'terraform apply tfplan'
            }
        }

        stage('Destroy auto-approve') {
            when {
                expression { params.autoApprove && params.action == "destroy"}
            }
            steps {
                sh '''
                    terraform destroy \
                        -target=openstack_networking_floatingip_associate_v2.fip_associate \
                        -target=ovh_cloud_project_instance.gazebo_instance \
                        -target=ovh_cloud_project_gateway.gateway \
                        -target=ovh_cloud_project_network_private_subnet.private_subnet \
                        -target=ovh_cloud_project_network_private.private_net --auto-approve
                '''
            }
        }

        stage('Destroy !auto-approve') {
            when {
                expression { params.autoApprove == false && params.action == "destroy" }
            }
            steps {
                sh 'terraform destroy'
            }
        }
    }
}
