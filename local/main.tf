terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.0"
    }
  }
}

# Initialize the Docker provider
provider "docker" {}

# Pull the Nginx image
resource "docker_image" "nginx" {
  name         = "nginx:latest"
  keep_locally = false
}

# Create and run the container
resource "docker_container" "web" {
  image = docker_image.nginx.image_id
  name  = "my_web_server"
  
  ports {
    internal = 80
    external = 8080
  }
}