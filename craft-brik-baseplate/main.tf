terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
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

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"

  startup_script = <<-EOT
    set -e

    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends ca-certificates apt-transport-https software-properties-common wget gpg curl jq git lsb-release

    sudo add-apt-repository ppa:ondrej/php
    sudo apt-get update -y

    sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y tzdata
    sudo dpkg-reconfigure --frontend noninteractive tzdata

    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
    export NVM_DIR="$HOME/.nvm" && \
      [ -s "$NVM_DIR/nvm.sh" ]    && \
      . "$NVM_DIR/nvm.sh"         && \
      nvm install node            && \
      npm i -g pnpm npm

    echo ". ~/.nvm/nvm.sh" >> /home/coder/.bashrc

    sudo apt-get install -y --no-install-recommends php8.3 \
      php8.3-simplexml php8.3-bcmath php8.3-curl \
      php8.3-dom php8.3-gd php8.3-intl php8.3-zip \
      php8.3-pdo php8.3-mysql php8.3-pgsql php8.3-fpm \
      php8.3-mbstring php8.3-imagick

    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    sudo php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    php -r "unlink('composer-setup.php');"

    sudo apt-get install -y postgresql-common
    sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    # don't autocreate the main cluster after installing postgresql-16. if it already exists, we needn't mess around
    # sudo sed -i 's/#create_main_cluster = true/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf

    # if we've already got data here, correct the permissions
    if [ -d /var/lib/postgresql/16/main ]; then
      sudo chmod -R 0700 /var/lib/postgresql/16/main
      sudo chown -R postgres:postgres /var/lib/postgresql/16/main
    fi
    sudo apt-get install -y postgresql-16
    sudo -u postgres pg_ctlcluster 16 main start

    # no `craft` database present
    if [ "$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -c craft)" -eq 0 ]; then
      sudo -u postgres createdb -e craft
      sudo -u postgres psql -c "ALTER USER postgres with encrypted password 'root';"
    fi

    # install and run redis
    sudo apt-get -y install 
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    sudo chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
    sudo apt-get update -y
    sudo apt-get install -y redis
    sudo service redis-server start

    # baseplate isn't there, set it up
    if [ ! -d craft-baseplate ]; then composer create-project brikdigital/craft-baseplate --no-scripts; fi
    cd craft-baseplate
    cp .env.example.dev .env

    # we haven't touched this yet
    if [ "$(cat .env | grep -c 'CRAFT_DB_DATABASE=craft')" -eq 0 ]; then
      sed -i 's/DRIVER=mysql/DRIVER=pgsql/' .env
      sed -i 's/PORT=3306/PORT=5432/' .env
      sed -i 's/DATABASE=/DATABASE=craft/' .env
      sed -i 's/USER=root/USER=postgres/' .env
      sed -i 's/PASSWORD=/PASSWORD=root/' .env
      sed -i 's/REDIS_HOSTNAME=/REDIS_HOSTNAME=localhost/' .env
      sed -i 's/REDIS_PORT=/REDIS_PORT=6379/' .env
    fi

    # craft reports not being installed
    if [ "$(php craft install/check | grep -c 'not installed')" -eq 1 ]; then
      php craft install --interactive=0 \
        --email="alyxia@riseup.net" --password="rooted"
    fi

    php craft serve >/tmp/craft.log 2>&1 &

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.11.0
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
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

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}
