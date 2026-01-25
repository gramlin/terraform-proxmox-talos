#KOM IHÅG ATT HÅLLA DENNA HEMLIG
unset HTTPS_PROXY

export TF_VAR_proxmox_pve_node_address='myi8'

export PROXMOX_VE_ENDPOINT='https://myip:8006'
export PROXMOX_VE_INSECURE='1'
export PROXMOX_VE_USERNAME='root'
# API-token auth (REKOMMENDERAT)
export PROXMOX_VE_API_TOKEN='terraform@pve!terraform=xxxxxxx.....'
# SSH används för diskoperationer
export PROXMOX_VE_SSH_USERNAME='root'
export PROXMOX_VE_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)"
export TF_CLI_ARGS_apply="-parallelism=1"
export TF_CLI_ARGS_plan="-parallelism=1"
