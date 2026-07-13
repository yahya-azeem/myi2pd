#!/bin/bash
# deploy_or_restore.sh - Orchestrates either a fresh Vultr deployment or an in-place snapshot restore if VPS_IP is configured in Secrets.

set -e

if [ -z "$VULTR_API_KEY" ]; then
    echo "[ERROR] VULTR_API_KEY environment variable is not set."
    exit 1
fi

echo "=== Vultr myi2pd Deployment/Restore Manager ==="

# 1. Clean up conflicting SSH keys
echo "Checking for conflicting myi2pd SSH keys..."
KEYS_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/ssh-keys" -H "Authorization: Bearer ${VULTR_API_KEY}")

if ! echo "$KEYS_JSON" | jq -e '.ssh_keys' >/dev/null 2>&1; then
    echo "[ERROR] Invalid response from Vultr SSH keys API. Response:"
    echo "$KEYS_JSON"
    exit 1
fi

KEY_IDS=$(echo "$KEYS_JSON" | jq -r '.ssh_keys[] | select(.name == "myi2pd-ssh-key") | .id')

if [ -n "$KEY_IDS" ]; then
    for id in $KEY_IDS; do
        echo "Found conflicting SSH key ID: $id. Deleting..."
        curl -s -X DELETE -A "vultr-cli/v2.22.0" "https://api.vultr.com/v2/ssh-keys/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
    done
fi

# 2. Check if VPS_IP is configured and exists on Vultr
EXISTING_INSTANCE_ID=""
if [ -n "$VPS_IP" ]; then
    echo "VPS_IP secret is configured: $VPS_IP. Checking Vultr instances..."
    INSTANCES_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/instances" -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    if ! echo "$INSTANCES_JSON" | jq -e '.instances' >/dev/null 2>&1; then
        echo "[ERROR] Invalid response from Vultr instances API. Response:"
        echo "$INSTANCES_JSON"
        exit 1
    fi
    
    EXISTING_INSTANCE_ID=$(echo "$INSTANCES_JSON" | jq -r --arg ip "$VPS_IP" '.instances[] | select(.main_ip == $ip) | .id')
fi

# 3. Perform Deploy or Restore
if [ -n "$EXISTING_INSTANCE_ID" ]; then
    echo "[OK] Found existing instance ID: $EXISTING_INSTANCE_ID matching IP: $VPS_IP."
    echo "We will perform an IN-PLACE snapshot restore to update the VPS while keeping the IP address!"

    # Delete old snapshot to stay in Vultr free allocations
    echo "Checking for conflicting myi2pd snapshots..."
    SNAP_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/snapshots" -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    if ! echo "$SNAP_JSON" | jq -e '.snapshots' >/dev/null 2>&1; then
        echo "[ERROR] Invalid response from Vultr snapshots API. Response:"
        echo "$SNAP_JSON"
        exit 1
    fi
    
    SNAP_IDS=$(echo "$SNAP_JSON" | jq -r '.snapshots[] | select(.description == "myi2pd-hardened-alpine-vps") | .id')
    
    if [ -n "$SNAP_IDS" ]; then
        for id in $SNAP_IDS; do
            echo "Deleting old snapshot ID: $id..."
            curl -s -X DELETE -A "vultr-cli/v2.22.0" "https://api.vultr.com/v2/snapshots/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
        done
    fi

    # Build new snapshot using Packer
    echo "Running Packer to compile new hardened VPS snapshot..."
    cd vps/packer
    packer init vps_image.pkr.hcl
    packer build vps_image.pkr.hcl
    cd ../..

    # Retrieve newly generated snapshot ID
    echo "Retrieving new snapshot ID..."
    NEW_SNAP_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/snapshots" -H "Authorization: Bearer ${VULTR_API_KEY}")
    NEW_SNAP_ID=$(echo "$NEW_SNAP_JSON" | jq -r '.snapshots[] | select(.description == "myi2pd-hardened-alpine-vps") | .id' | head -n 1)

    if [ -z "$NEW_SNAP_ID" ] || [ "$NEW_SNAP_ID" = "null" ]; then
        echo "[ERROR] Failed to locate the newly built Packer snapshot."
        exit 1
    fi
    echo "New snapshot ID: $NEW_SNAP_ID"

    # Call Vultr API to restore the snapshot onto the instance
    echo "Triggering Vultr snapshot restore on instance: $EXISTING_INSTANCE_ID..."
    curl -s -X POST -A "vultr-cli/v2.22.0" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      --data "{\"instance_id\": \"$EXISTING_INSTANCE_ID\"}" \
      "https://api.vultr.com/v2/snapshots/$NEW_SNAP_ID/restore"

    echo "Snapshot restore triggered successfully! The VPS IP address remains: $VPS_IP"
    echo "=================================================="
    echo "    myi2pd VPS Gateway successfully updated!      "
    echo "    Public IP Address remains: $VPS_IP            "
    echo "=================================================="

else
    echo "No existing instance found matching VPS_IP (or VPS_IP not set)."
    echo "Performing a fresh Terraform clean-deployment..."

    # Purge any conflicting myi2pd instances (Stay in Free Tier)
    echo "Checking for conflicting myi2pd instances..."
    INSTANCES_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/instances" -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    if ! echo "$INSTANCES_JSON" | jq -e '.instances' >/dev/null 2>&1; then
        echo "[ERROR] Invalid response from Vultr instances API. Response:"
        echo "$INSTANCES_JSON"
        exit 1
    fi
    
    CONFLICTING_IDS=$(echo "$INSTANCES_JSON" | jq -r '.instances[] | select(.label == "myi2pd-gateway" or .tag == "myi2pd") | .id')
    
    if [ -n "$CONFLICTING_IDS" ]; then
        for id in $CONFLICTING_IDS; do
            echo "Destroying conflicting instance ID: $id..."
            curl -s -X DELETE -A "vultr-cli/v2.22.0" "https://api.vultr.com/v2/instances/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
        done
        
        echo "Waiting for instance deletion to finish..."
        while true; do
            sleep 10
            CHECK_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/instances" -H "Authorization: Bearer ${VULTR_API_KEY}")
            REMAINING=$(echo "$CHECK_JSON" | jq -r '.instances[] | select(.label == "myi2pd-gateway" or .tag == "myi2pd") | .id')
            if [ -z "$REMAINING" ]; then
                break
            fi
            echo "Waiting for termination of: $REMAINING..."
        done
    fi

    # Delete old snapshots
    echo "Cleaning up conflicting snapshots..."
    SNAP_JSON=$(curl -s -A "vultr-cli/v2.22.0" -H "Accept: application/json" "https://api.vultr.com/v2/snapshots" -H "Authorization: Bearer ${VULTR_API_KEY}")
    SNAP_IDS=$(echo "$SNAP_JSON" | jq -r '.snapshots[] | select(.description == "myi2pd-hardened-alpine-vps") | .id')
    
    if [ -n "$SNAP_IDS" ]; then
        for id in $SNAP_IDS; do
            echo "Deleting snapshot ID: $id..."
            curl -s -X DELETE -A "vultr-cli/v2.22.0" "https://api.vultr.com/v2/snapshots/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
        done
    fi

    # Build new snapshot using Packer
    echo "Running Packer to compile new hardened VPS snapshot..."
    cd vps/packer
    packer init vps_image.pkr.hcl
    packer build vps_image.pkr.hcl
    cd ../..

    # Deploy instance from snapshot using Terraform
    echo "Initializing and running Terraform..."
    cd vps/terraform
    terraform init
    export TF_VAR_vultr_api_key="$VULTR_API_KEY"
    terraform apply -auto-approve
    
    # Print the new IP address
    NEW_VPS_IP=$(terraform output -raw vps_ip)
    cd ../..
    
    echo "=================================================="
    echo "    myi2pd VPS Gateway successfully deployed!     "
    echo "    Public IP Address: $NEW_VPS_IP                "
    echo "    IMPORTANT: Add this IP as a GitHub Repository "
    echo "    Secret named 'VPS_IP' to preserve it on       "
    echo "    future runs.                                  "
    echo "=================================================="
fi
