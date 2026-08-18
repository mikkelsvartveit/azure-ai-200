#!/usr/bin/env bash

# Change the values of these variables as needed

rg="rg-app-service"  # Resource Group name
location="westeurope"   # Azure region for the resources

# ============================================================================
# DON'T CHANGE ANYTHING BELOW THIS LINE.
# ============================================================================

# Disable Git Bash forward-slash path conversion (Windows only; no-op elsewhere).
export MSYS_NO_PATHCONV=1

# ----------------------------------------------------------------------------
# Error handling helpers
# ----------------------------------------------------------------------------

# Print a captured command output as an indented, truncated error detail block.
print_error_details() {
    local output="$1"
    local max_lines=40

    echo "  ----------------------------- details -----------------------------"
    if [ -z "$output" ]; then
        echo "  (no output captured from Azure CLI)"
    else
        local total_lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
        if [ "$total_lines" -gt "$max_lines" ]; then
            echo "  (showing last $max_lines of $total_lines lines)"
            printf '%s\n' "$output" | tail -n "$max_lines" | sed 's/^/  /'
        else
            printf '%s\n' "$output" | sed 's/^/  /'
        fi
    fi
    echo "  -------------------------------------------------------------------"
}

# Run an Azure CLI command, hiding output on success and showing it on failure.
# Usage: run_az "<description of the step>" az <args...>
run_az() {
    local description="$1"
    shift

    local output
    local status
    output=$("$@" 2>&1)
    status=$?

    if [ $status -ne 0 ]; then
        echo "Error: $description failed (exit code $status)."
        echo "  Command: $*"
        print_error_details "$output"
        return $status
    fi
    return 0
}

# Summarize a failed menu step so the failure is not lost above the prompt.
report_failure() {
    echo ""
    echo "✗ Step '$1' did not complete. Fix the problem above and select the option again."
}

# Compute a short hash; sha1sum is not present on stock macOS, shasum is.
hash_string() {
    if command -v sha1sum > /dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | cut -c1-8
    elif command -v shasum > /dev/null 2>&1; then
        printf '%s' "$1" | shasum | cut -c1-8
    else
        echo ""
    fi
}

# ----------------------------------------------------------------------------
# Preflight checks
# ----------------------------------------------------------------------------

# Run from the script's own directory so the relative 'api/' paths always resolve.
script_dir=$(cd "$(dirname "$0")" && pwd)
if [ -z "$script_dir" ] || ! cd "$script_dir"; then
    echo "Error: Could not change into the script directory '$(dirname "$0")'."
    exit 1
fi

if ! command -v az > /dev/null 2>&1; then
    echo "Error: The Azure CLI ('az') was not found on your PATH."
    echo "  Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

# Generate consistent hash from Azure user object ID (based on az login account)
user_object_id=$(az ad signed-in-user show --query "id" -o tsv 2>&1)
if [ $? -ne 0 ] || [ -z "$user_object_id" ]; then
    echo "Error: Could not determine the signed-in Azure user."
    echo "  Make sure you are logged in with: az login"
    print_error_details "$user_object_id"
    exit 1
fi

# Verify an active subscription is selected, since every resource command needs one.
subscription_name=$(az account show --query "name" -o tsv 2>&1)
if [ $? -ne 0 ] || [ -z "$subscription_name" ]; then
    echo "Error: No active Azure subscription is selected."
    echo "  List your subscriptions with:  az account list -o table"
    echo "  Then select one with:          az account set --subscription <name-or-id>"
    print_error_details "$subscription_name"
    exit 1
fi

user_hash=$(hash_string "$user_object_id")
if [ -z "$user_hash" ]; then
    echo "Error: Neither 'sha1sum' nor 'shasum' is available, cannot generate resource name suffix."
    echo "  On macOS, install coreutils with: brew install coreutils"
    exit 1
fi

# Resource names with hash for uniqueness
acr_name="acr${user_hash}"
app_plan="plan-docprocessor-${user_hash}"
app_name="app-docprocessor-${user_hash}"
container_image="docprocessor:v1"

# Function to display menu
show_menu() {
    clear
    echo "====================================================================="
    echo "    App Service Container Exercise - Deployment Script"
    echo "====================================================================="
    echo "Subscription: $subscription_name"
    echo "Resource Group: $rg"
    echo "Location: $location"
    echo "ACR Name: $acr_name"
    echo "App Service Plan: $app_plan"
    echo "====================================================================="
    echo "1. Create Azure Container Registry and build container image"
    echo "2. Create App Service Plan"
    echo "3. Check deployment status"
    echo "4. Exit"
    echo "====================================================================="
}

# Function to create resource group if it doesn't exist
create_resource_group() {
    echo "Checking/creating resource group '$rg'..."

    local exists
    exists=$(az group exists --name $rg 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error: Could not check whether resource group '$rg' exists."
        print_error_details "$exists"
        return 1
    fi

    if [ "$exists" = "false" ]; then
        run_az "Creating resource group '$rg' in '$location'" \
            az group create --name $rg --location $location || return 1
        echo "✓ Resource group created: $rg"
    else
        echo "✓ Resource group already exists: $rg"
    fi
}

# Function to create Azure Container Registry and build image
create_acr_and_build_image() {
    echo "Creating Azure Container Registry '$acr_name'..."

    if az acr show --resource-group $rg --name $acr_name > /dev/null 2>&1; then
        echo "✓ ACR already exists: $acr_name"
        echo "  Login server: $acr_name.azurecr.io"
    else
        if ! run_az "Creating container registry '$acr_name'" \
            az acr create \
                --resource-group $rg \
                --name $acr_name \
                --sku Basic \
                --admin-enabled false; then
            echo "  Common causes:"
            echo "    - The registry name is already taken (ACR names are globally unique)."
            echo "    - Your account lacks permission to create resources in '$rg'."
            echo "    - The subscription has not registered the Microsoft.ContainerRegistry provider:"
            echo "        az provider register --namespace Microsoft.ContainerRegistry"
            return 1
        fi
        echo "✓ ACR created: $acr_name"
        echo "  Login server: $acr_name.azurecr.io"
    fi

    echo ""
    echo "Building and pushing container image to ACR..."
    echo "This may take a few minutes..."

    if [ ! -f "api/Dockerfile" ]; then
        echo "Error: Dockerfile not found at '$(pwd)/api/Dockerfile'."
        echo "  The 'api' folder must sit next to this script."
        return 1
    fi

    # Build image using ACR Tasks. Build logs are captured and only shown on failure.
    if ! run_az "Building and pushing image '$container_image'" \
        az acr build \
            --resource-group $rg \
            --registry $acr_name \
            --image $container_image \
            --file api/Dockerfile \
            api/; then
        echo "  Common causes:"
        echo "    - A failing step in api/Dockerfile (see the build log above)."
        echo "    - No quota for ACR Tasks agents in this region, or the registry is unreachable."
        return 1
    fi
    echo "✓ Image built and pushed: $acr_name.azurecr.io/$container_image"
}

# Function to create App Service Plan
create_app_service_plan() {
    echo "Creating App Service Plan '$app_plan'..."

    if az appservice plan show --resource-group $rg --name $app_plan > /dev/null 2>&1; then
        echo "✓ App Service Plan already exists: $app_plan"
    else
        if ! run_az "Creating App Service Plan '$app_plan'" \
            az appservice plan create \
                --resource-group $rg \
                --name $app_plan \
                --sku B1 \
                --is-linux; then
            echo "  Common causes:"
            echo "    - The B1 SKU is unavailable or out of quota in '$location'."
            echo "      Check with: az appservice list-locations --sku B1 --linux-workers-enabled -o table"
            echo "    - The subscription quota for App Service Plans is exhausted."
            echo "    - Your account lacks permission to create resources in '$rg'."
            echo "    - The Microsoft.Web provider is not registered:"
            echo "        az provider register --namespace Microsoft.Web"
            return 1
        fi
        echo "✓ App Service Plan created: $app_plan"
        echo "  SKU: B1 (Basic tier - supports always-on and custom containers)"
    fi

    # Write environment variables to file
    write_env_file
}

# Function to write environment variables to file
write_env_file() {
    local env_file="$script_dir/.env"
    if ! cat > "$env_file" << EOF
export RESOURCE_GROUP="$rg"
export ACR_NAME="$acr_name"
export APP_PLAN="$app_plan"
export APP_NAME="$app_name"
export LOCATION="$location"
EOF
    then
        echo ""
        echo "Error: Could not write environment file '$env_file' (check directory permissions)."
        return 1
    fi
    echo ""
    echo "Environment variables saved to: $env_file"
    echo "Run 'source .env' to load them into your shell."
}

# Function to check deployment status
check_deployment_status() {
    echo "Checking deployment status..."
    echo ""

    # Check ACR
    echo "Azure Container Registry ($acr_name):"
    local acr_status=$(az acr show --resource-group $rg --name $acr_name --query "provisioningState" -o tsv 2>/dev/null)
    if [ ! -z "$acr_status" ]; then
        echo "  Status: $acr_status"
        if [ "$acr_status" = "Succeeded" ]; then
            echo "  ✓ ACR is ready"
            # Check if image exists
            local image_exists=$(az acr repository show --name $acr_name --image $container_image 2>/dev/null)
            if [ ! -z "$image_exists" ]; then
                echo "  ✓ Container image: $container_image"
            else
                echo "  Container image not found"
            fi
        fi
    else
        echo "  Status: Not created"
    fi

    # Check App Service Plan
    echo ""
    echo "App Service Plan ($app_plan):"
    local plan_status=$(az appservice plan show --resource-group $rg --name $app_plan --query "provisioningState" -o tsv 2>/dev/null)
    if [ ! -z "$plan_status" ]; then
        echo "  Status: $plan_status"
        local plan_sku=$(az appservice plan show --resource-group $rg --name $app_plan --query "sku.name" -o tsv 2>/dev/null)
        echo "  SKU: $plan_sku"
        if [ "$plan_status" = "Succeeded" ]; then
            echo "  ✓ App Service Plan is ready"
        fi
    else
        echo "  Status: Not created"
    fi

    # Check Web App
    echo ""
    echo "Web App ($app_name):"
    local app_state=$(az webapp show --resource-group $rg --name $app_name --query "state" -o tsv 2>/dev/null)
    if [ ! -z "$app_state" ]; then
        echo "  State: $app_state"
        echo "  URL: https://$app_name.azurewebsites.net"

        # Check managed identity
        local identity=$(az webapp identity show --resource-group $rg --name $app_name --query "principalId" -o tsv 2>/dev/null)
        if [ ! -z "$identity" ]; then
            echo "  ✓ Managed identity configured"
        else
            echo "  Managed identity: Not configured"
        fi
    else
        echo "  Status: Not created (student task)"
    fi

    echo ""
    echo "====================================================================="
    echo "Environment Variables (.env file):"
    echo "  RESOURCE_GROUP=$rg"
    echo "  ACR_NAME=$acr_name"
    echo "  APP_PLAN=$app_plan"
    echo "  APP_NAME=$app_name"
    echo "  LOCATION=$location"
    echo "====================================================================="
}

# Main menu loop
while true; do
    show_menu
    read -p "Please select an option (1-4): " choice

    case $choice in
        1)
            echo ""
            if create_resource_group; then
                echo ""
                create_acr_and_build_image || report_failure "container registry / image build"
            else
                report_failure "resource group"
            fi
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            echo ""
            if create_resource_group; then
                echo ""
                create_app_service_plan || report_failure "App Service Plan"
            else
                report_failure "resource group"
            fi
            echo ""
            read -p "Press Enter to continue..."
            ;;
        3)
            echo ""
            check_deployment_status
            echo ""
            read -p "Press Enter to continue..."
            ;;
        4)
            echo "Exiting..."
            clear
            exit 0
            ;;
        *)
            echo "Invalid option. Please select 1-4."
            read -p "Press Enter to continue..."
            ;;
    esac
done
