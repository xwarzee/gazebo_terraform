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
        TF_VAR_project_id_var = credentials('TF_VAR_project_id_var')
        TF_VAR_application_secret_var = credentials('TF_VAR_application_secret_var')
        TF_VAR_consumer_key_var = credentials('TF_VAR_consumer_key_var')
        TF_VAR_application_key_var = credentials('TF_VAR_application_key_var')
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
                sh '''
                    terraform apply \
                        -target=ovh_cloud_project_network_private.private_net \
                        -target=ovh_cloud_project_network_private_subnet.private_subnet \
                        -target=ovh_cloud_project_gateway.gateway \
                        -target=ovh_cloud_project_instance.gazebo_instance --auto-approve
                    terraform apply -auto-approve
                '''
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
