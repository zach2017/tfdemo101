Setting up a local infrastructure playground is a great way to learn these tools. Since you are using Docker, we can use a very elegant approach:

1. **Terraform** will spin up an Nginx web server container.
2. **Ansible** will connect directly to that running container using its native Docker connection (no SSH required) to inject your custom HTML page.

Create a new folder on your Mac (e.g., `mkdir ~/local-lab && cd ~/local-lab`) and follow the steps below.

---

### Phase 1: Infrastructure with Terraform

First, we will define our Docker infrastructure using Terraform.

**1. Create a file named `main.tf**`
Add the following code to the file. This tells Terraform to download the Nginx image and run it as a container, exposing port 8080.

```hcl
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

```

**2. Deploy the container**
Run these commands in your terminal (ensure your Docker Desktop app is open and running):

```bash
# Download the required Docker provider plugin
terraform init

# Review and apply the configuration
terraform apply -auto-approve

```

If you go to `http://localhost:8080` in your browser right now, you will see the default "Welcome to nginx!" screen.

---

### Phase 2: Configuration with Ansible

Now, let's use Ansible to configure that server by replacing the default page with a custom "Hello World" HTML page.

**1. Create an inventory file named `inventory.ini**`
This file tells Ansible where your servers are. We are telling it to target the exact container name Terraform just created, and to connect via Docker rather than SSH.

```ini
[webservers]
my_web_server ansible_connection=docker

```

**2. Create a playbook file named `playbook.yml**`
This is the script that executes your configuration. Because standard Nginx containers don't have Python installed (which Ansible usually requires), we will use Ansible's `raw` module to run a direct shell command to build the HTML file.

```yaml
---
- name: Configure Web Server with Hello World
  hosts: webservers
  # We disable fact gathering because the container doesn't have Python installed
  gather_facts: false 
  tasks:
    - name: Write custom index.html into the Nginx directory
      raw: |
        echo '<html>
                <head><title>Ansible & Terraform</title></head>
                <body>
                  <h1>Hello World!</h1>
                  <p>Provisioned by Terraform, configured locally by Ansible.</p>
                </body>
              </html>' > /usr/share/nginx/html/index.html

```

**3. Run the playbook**
Execute the following command in your terminal to apply the configuration:

```bash
ansible-playbook -i inventory.ini playbook.yml

```

---

### Phase 3: Verify and Clean Up

**Verify:**
Refresh `http://localhost:8080` in your browser. You should now see your custom "Hello World!" page instead of the default Nginx page.

**Clean up:**
When you are done experimenting, you can easily tear down the infrastructure Terraform created. Run this command to stop and remove the Docker container:

```bash
terraform destroy -auto-approve

```