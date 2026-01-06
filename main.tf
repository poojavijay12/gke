terraform {
  required_version = ">= 1.5.0"
  backend "gcs" {
    bucket  = "pooja31-terraform-state"
    prefix  = "gke"
  }

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

data "google_client_config" "default" {}

############################################
# GKE CLUSTER (SECURITY FIRST - ZONAL)
############################################
resource "google_container_cluster" "gke" {
  name     = "secure-gke"
  location = "asia-south1-a"

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
}

############################################
# NODE POOL (ZONAL + LOW DISK)
############################################
resource "google_container_node_pool" "nodes" {
  name     = "primary"
  cluster  = google_container_cluster.gke.name
  location = "asia-south1-a"

  node_count = 2

  node_config {
    machine_type = "e2-medium"

    disk_type    = "pd-balanced"
    disk_size_gb = 50

    shielded_instance_config {
      enable_secure_boot = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

############################################
# KUBERNETES PROVIDER (FIXED)
############################################
provider "kubernetes" {
  host                   = "https://${google_container_cluster.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.gke.master_auth[0].cluster_ca_certificate
  )
}

############################################
# APPLICATION DEPLOYMENT
############################################
resource "kubernetes_deployment" "app" {
  depends_on = [
    google_container_node_pool.nodes
  ]

  metadata {
    name = "fastapi-app"
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
  depends_on = [
    kubernetes_deployment.app
  ]

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
# OUTPUTS
############################################
output "gke_cluster_name" {
  value = google_container_cluster.gke.name
}

output "service_ip" {
  value = kubernetes_service.svc.status[0].load_balancer[0].ingress[0].ip
}
