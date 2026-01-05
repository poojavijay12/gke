############################################
# TERRAFORM & PROVIDERS
############################################
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

provider "google" {
  project = "pooja31"
  region  = "asia-south1"
}

############################################
# PROJECT DATA (PROJECT NUMBER IS CRITICAL)
############################################
data "google_project" "current" {
  project_id = "pooja31"
}

data "google_client_config" "default" {}

############################################
# STEP 1: ENABLE REQUIRED APIS
############################################
resource "google_project_service" "services" {
  for_each = toset([
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sts.googleapis.com",
    "artifactregistry.googleapis.com"
  ])

  service = each.value
}

############################################
# STEP 2: CI/CD SERVICE ACCOUNT
############################################
resource "google_service_account" "terraform_cicd" {
  account_id   = "terraform-cicd"
  display_name = "Terraform CI/CD Service Account"
}

############################################
# STEP 3: IAM ROLES (MINIMUM REQUIRED)
############################################
resource "google_project_iam_member" "cicd_roles" {
  for_each = toset([
    "roles/container.admin",
    "roles/iam.serviceAccountUser",
    "roles/storage.admin"
  ])

  role   = each.value
  member = "serviceAccount:${google_service_account.terraform_cicd.email}"
}

############################################
# STEP 4: WORKLOAD IDENTITY POOL
############################################
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  location                  = "global"

  depends_on = [google_project_service.services]
}

############################################
# STEP 5: OIDC PROVIDER (GITHUB)
############################################
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  location                           = "global"
  display_name                       = "GitHub OIDC Provider"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
}

############################################
# STEP 6: BIND GITHUB REPO → SERVICE ACCOUNT
############################################
resource "google_service_account_iam_member" "github_binding" {
  service_account_id = google_service_account.terraform_cicd.name
  role               = "roles/iam.workloadIdentityUser"

  member = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_pool.workload_identity_pool_id}/attribute.repository/poojavijay12/gke"
}

############################################
# GKE CLUSTER (SECURITY FIRST)
############################################
resource "google_container_cluster" "gke" {
  name     = "secure-gke"
  location = "asia-south1"

  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "pooja31.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.services]
}

############################################
# NODE POOL
############################################
resource "google_container_node_pool" "nodes" {
  name      = "primary"
  cluster   = google_container_cluster.gke.name
  location  = "asia-south1"
  node_count = 2

  node_config {
    machine_type = "e2-medium"

    shielded_instance_config {
      enable_secure_boot = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

############################################
# KUBERNETES PROVIDER
############################################
provider "kubernetes" {
  host                   = google_container_cluster.gke.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.gke.master_auth[0].cluster_ca_certificate
  )
}

############################################
# APPLICATION DEPLOYMENT
############################################
resource "kubernetes_deployment" "app" {
  metadata {
    name   = "fastapi-app"
    labels = { app = "fastapi" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "fastapi" }
    }

    template {
      metadata {
        labels = { app = "fastapi" }
      }

      spec {
        container {
          name  = "fastapi"
          image = "gcr.io/pooja31/fastapi-gke:latest"

          port {
            container_port = 8080
          }

          security_context {
            run_as_non_root = true
            run_as_user     = 1000
          }
        }
      }
    }
  }
}

############################################
# SERVICE (LOAD BALANCER)
############################################
resource "kubernetes_service" "svc" {
  metadata {
    name = "fastapi-service"
  }

  spec {
    selector = { app = "fastapi" }

    port {
      port        = 80
      target_port = 8080
    }

    type = "LoadBalancer"
  }
}

############################################
# OUTPUTS (TERRAFORMIC)
############################################
output "project_number" {
  value = data.google_project.current.number
}

output "gke_cluster_name" {
  value = google_container_cluster.gke.name
}

output "ci_cd_service_account" {
  value = google_service_account.terraform_cicd.email
}

output "workload_identity_pool" {
  value = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
}

output "service_ip" {
  value = kubernetes_service.svc.status[0].load_balancer[0].ingress[0].ip
}
