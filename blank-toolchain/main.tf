terraform {
  required_providers {
    coder = {
      source = "coder/coder"
      version = ">=2.8.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">=2.37.1"
    }
  }
}

provider "coder" {
}

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces). If the Coder host is itself running as a Pod on the same Kubernetes cluster as you are deploying workspaces to, set this to the same namespace."
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os             = data.coder_provisioner.me.os
  arch           = data.coder_provisioner.me.arch

  env = {
    "TOOLSET" = data.coder_parameter.toolset.value
  }

  startup_script = <<-EOT
    set -e

    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends ca-certificates apt-transport-https software-properties-common wget gpg curl jq git

    if [ "$TOOLSET" == "javascript" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
      export NVM_DIR="$HOME/.nvm" && \
        [ -s "$NVM_DIR/nvm.sh" ]    && \
        . "$NVM_DIR/nvm.sh"         && \
        nvm install node            && \
        npm i -g pnpm npm
    fi

    if [ "$TOOLSET" == "php" ]; then
      sudo add-apt-repository ppa:ondrej/php
      sudo apt-get update -y

      sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y tzdata
      sudo dpkg-reconfigure --frontend noninteractive tzdata

      sudo apt-get install -y --no-install-recommends php8.3 \
        php8.3-simplexml php8.3-bcmath php8.3-curl \
        php8.3-dom php8.3-gd php8.3-intl php8.3-zip \
        php8.3-pdo php8.3-mysql php8.3-pgsql php8.3-fpm

      #curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | \
      #  sudo gpg --dearmor -o /etc/apt/keyrings/mysql-keyring.gpg
      #echo "deb [signed-by=/etc/apt/keyrings/mysql-keyring.gpg] https://repo.mysql.com/apt/ubuntu noble mysql-8.0" | \
      #  sudo tee -a /etc/apt/sources.list
      #sudo apt update
      #sudo apt install -y mysql-server

      sudo apt-get install -y postgresql-common
      sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
      sudo apt-get install -y postgresql-16
      sudo -u postgres pg_ctlcluster 16 main start

      php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
      sudo php composer-setup.php --install-dir=/usr/local/bin --filename=composer
      php -r "unlink('composer-setup.php');"
    fi

    if [ "$TOOLSET" == "go" ]; then
      sudo apt-get update -y
      sudo apt-get install build-essential
      wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
      sudo rm -rf /usr/local/go && \
        sudo tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
      rm -rf go1.22.5.linux-amd64.tar.gz
    fi
  EOT

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "IP Address"
    key          = "0_ip_address"
    script       = "hostname -i"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage"
    key          = "1_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "2_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}

module "coder-login" {
  count  = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/coder-login/coder"

  version  = ">=1.0.30"
  agent_id = coder_agent.main.id
}

module "code-server" {
  count  = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"

  version  = ">=1.3.0"
  agent_id = coder_agent.main.id

  subdomain = true
  folder = "~/craft-baseplate"
  settings = {
    "telemetry.telemetryLevel" = "off"
  }
}

module "jetbrains_gateway" {
  count  = data.coder_workspace.me.start_count
  source         = "registry.coder.com/modules/jetbrains-gateway/coder"

  version        = ">=1.2.1"
  agent_id       = coder_agent.main.id

  latest         = true
  folder         = "/home/coder"
  jetbrains_ides = ["IU", "PS", "WS", "PY", "CL", "GO", "RM", "RD", "RR"]
  default        = "WS"
}