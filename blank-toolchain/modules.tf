module "git-commit-signing" {
  count    = data.coder_external_auth.github.access_token != "" ? 1 : 0
  source   = "registry.coder.com/coder/git-commit-signing/coder"
  version  = "1.0.11"
  agent_id = coder_agent.main.id
}

module "github-upload-public-key" {
  count    = data.coder_external_auth.github.access_token != "" ? 1 : 0
  source   = "registry.coder.com/coder/github-upload-public-key/coder"
  version  = "1.0.15"
  agent_id = coder_agent.main.id
  external_auth_id = data.coder_external_auth.github.id
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