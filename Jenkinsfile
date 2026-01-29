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
                    terraform apply -auto-approve tfplan
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
                expression { params.autoApprove && params.action == "apply"}
            }
            steps {
                sh '''
                    terraform destroy -auto-approve 
                '''
            }
        }

        stage('Destroy !auto-approve') {
            when {
                expression { params.autoApprove == false && params.action == "apply" }
            }
            steps {
                sh 'terraform destroy'
            }
        }
    }
}
