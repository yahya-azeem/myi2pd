#!/bin/bash
# destroy_old_vps.sh - Finds and destroys pre-existing myi2pd VPS instances and SSH keys to stay within Vultr Free Tier limits.

set -e

if [ -z "$VULTR_API_KEY" ]; then
    echo "[ERROR] VULTR_API_KEY environment variable is not set."
    exit 1
fi

echo "=== Vultr myi2pd Conflict Cleanup ==="

# 1. Fetch instances and search for myi2pd labeled/tagged instances
echo "Checking for pre-existing myi2pd instances..."
INSTANCES_JSON=$(curl -s "https://api.vultr.com/v2/instances" -H "Authorization: Bearer ${VULTR_API_KEY}")
INSTANCE_IDS=$(echo "$INSTANCES_JSON" | jq -r '.instances[] | select(.label == "myi2pd-gateway" or .tag == "myi2pd") | .id')

if [ -n "$INSTANCE_IDS" ]; then
    for id in $INSTANCE_IDS; do
        echo "Found pre-existing myi2pd instance ID: $id. Triggering destruction..."
        curl -s -X DELETE "https://api.vultr.com/v2/instances/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
    done
    
    # Poll until the instances are completely removed from Vultr account
    echo "Waiting for instance deletion to finish..."
    while true; do
        sleep 10
        CHECK_JSON=$(curl -s "https://api.vultr.com/v2/instances" -H "Authorization: Bearer ${VULTR_API_KEY}")
        REMAINING=$(echo "$CHECK_JSON" | jq -r '.instances[] | select(.label == "myi2pd-gateway" or .tag == "myi2pd") | .id')
        if [ -z "$REMAINING" ]; then
            echo "[OK] Conflicting instances successfully destroyed."
            break
        fi
        echo "Instances still terminating: $REMAINING. Retrying in 10s..."
    done
else
    echo "No conflicting myi2pd instances found."
fi

# 2. Fetch and delete conflicting SSH keys named "myi2pd-ssh-key"
echo "Checking for conflicting myi2pd SSH keys..."
KEYS_JSON=$(curl -s "https://api.vultr.com/v2/ssh-keys" -H "Authorization: Bearer ${VULTR_API_KEY}")
KEY_IDS=$(echo "$KEYS_JSON" | jq -r '.ssh_keys[] | select(.name == "myi2pd-ssh-key") | .id')

if [ -n "$KEY_IDS" ]; then
    for id in $KEY_IDS; do
        echo "Found conflicting SSH key ID: $id. Deleting..."
        curl -s -X DELETE "https://api.vultr.com/v2/ssh-keys/$id" -H "Authorization: Bearer ${VULTR_API_KEY}"
    done
    echo "[OK] Conflicting SSH keys deleted."
else
    echo "No conflicting myi2pd SSH keys found."
fi

echo "Vultr environment clean and ready for deployment."
