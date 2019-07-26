# exit on error
set -e

while getopts "gd:" opt; do
  case ${opt} in
    t ) 
      AAD_INTEGRATED_TENANT=$OPTARG
      ;;
    g ) 
      GROUP=$OPTARG
      ;;
    \? )
      echo "Unknown arg"
      show_usage=true
      
      ;; 
    esac
done

shift $((OPTIND -1))

if [ $# -ne 1 ] || [ "$show_usage" ]; then
    echo "Usage: $0 [-t tenentid] [-g resource_group_name] <cluster_name>"
    echo "Optional args:"
    echo " -t: provide an alternative tenant id to secure your aks cluster users (you will need ADMIN rights on the tenant)"
    echo " -g: provide a resource group name, otherwise it will default to the cluster_name-rg"
    exit 1
fi

# check nameing
# https://docs.microsoft.com/en-us/azure/architecture/best-practices/naming-conventions#containers

if [  "$AAD_INTEGRATED_TENANT" ]; then
    echo "You have selected an alternative tenent for cluster RBAC users, you will need to auth so we can create the required Apps, press ENTER to continue.."
    read
    az login --tenant $AAD_INTEGRATED_TENANT  --allow-no-subscriptions >/dev/null
else
    AAD_INTEGRATED_TENANT=$(az account show --query tenantId --output tsv)
fi


CLUSTER_NAME=${1}
GROUP=${GROUP:-"${CLUSTER_NAME}-rg"}

RAND5DIGIT=$(echo "${APP,,}$((RANDOM%9000+1000))" | tr -cd '[[:alnum:]]-' )

# App Service name : 2-60, Alphanumeric or -, (but not begining or ending with -)
if [[ ! "$CLUSTER_NAME" =~ ^([[:alnum:]]|-)*$ ]] || [[ "$CLUSTER_NAME" =~ ^-|-$ ]] || [ ${#CLUSTER_NAME} -gt 63 ] || [ ${#CLUSTER_NAME} -lt 2 ] ; then
    echo 'AKS cluster name can only container alpha numeric charactors or "-" (but not begining or ending with "-"), and be between 2-63 long'
    exit 1
fi

# Create the server application
# The Azure AD application you need gets Azure AD group membership for a user

# Delegate permissions for : Directory.Read.All
# Applicaion permissions for : Directory.Read.All
# Expose an API : Scope: ${ADSERVER_APP}, Admin Concent, 
# https://docs.microsoft.com/en-us/azure/aks/azure-ad-integration-cli

ADSERVER_APP="${CLUSTER_NAME}-ADServer"
ADCLIENT_APP="${CLUSTER_NAME}-ADClient"
echo "Creating Server app [${ADSERVER_APP}]..."
serverAppId=$(az ad app create --display-name $ADSERVER_APP --native-app false --reply-urls "https://${ADSERVER_APP}" --query appId -o tsv)

echo "Created/Patched [${ADSERVER_APP}], appId: ${serverAppId}"
# Update the application group memebership claims
az ad app update --id $serverAppId --set groupMembershipClaims=All >/dev/null


# Now create a service principal for the server app (specific to granting permissions to resources in this tenant)
# Create a service principal for the Azure AD application
echo "Create a service principal for the app...."
az ad sp create --id $serverAppId >/dev/null

# Get the service principal secret
serverAppSecret=$(az ad sp credential reset --name $serverAppId --credential-description "AKSPassword" --query password -o tsv)
echo "[${ADSERVER_APP}] secret: ${serverAppSecret}"

echo "Adding directory permissions for Delegate & Applicaion to Directory.Read.All..."
az ad app permission add \
    --id $serverAppId \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 06da0dbc-49e2-44d2-8312-53f166ab848a=Scope 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role

echo "Granting permissions..."
az ad app permission grant --id $serverAppId --api 00000003-0000-0000-c000-000000000000 >/dev/null
echo "Granting permissions ADMIN-consent..."
az ad app permission admin-consent --id  $serverAppId >/dev/null


#  Create the client application
#  Used when a user logon interactivlty to the AKS cluster with the Kubernetes CLI (kubectl)
echo "\nCreating Client app [${ADCLIENT_APP}]..."
clientAppId=$(az ad app create  --display-name $ADCLIENT_APP --native-app --reply-urls "https://${ADCLIENT_APP}" --query appId -o tsv)
echo "Created/Patched ${ADCLIENT_APP}, AppId: ${clientAppId}"

echo "Create a service principal for the app...."
az ad sp create --id $clientAppId >/dev/null

echo "Retreive the app outh permission id...."
oAuthPermissionId=$(az ad app show --id $serverAppId --query "oauth2Permissions[0].id" -o tsv)

echo "Adding the app permission....[${oAuthPermissionId}=Scope]"
az ad app permission add \
    --id $clientAppId \
    --api $serverAppId \
    --api-permissions ${oAuthPermissionId}=Scope

echo "Granting permissions..."
az ad app permission grant --id $clientAppId --api $serverAppId >/dev/null

echo "Changing back to defalt tenant to create Cluster"
az login

# https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough-rm-template#create-a-service-principal
echo "Create Service Principle for AKS to manage Azure Resources..."
AKS_SP=$(az ad sp create-for-rbac -n  "http://${CLUSTER_NAME}-sp" --skip-assignment  --query "[appId,password]" -o tsv)
AKS_SP_APPID=$(echo $AKS_SP | cut -f 1 -d ' ')
AKS_SP_SECRET=$(echo $AKS_SP | cut -f 2 -d ' ')

AKS_SP_OBJECTID=$(az ad sp show --id $AKS_SP_APPID --query objectId -o tsv)

az group create -l westeurope -n $CLUSTER_NAME
az group deployment create -g $CLUSTER_NAME \
    --template-file ./azuredeploy.json \
    --parameters \
        resourceName="${CLUSTER_NAME}" \
        dnsPrefix="${CLUSTER_NAME}" \
        existingServicePrincipalObjectId="${AKS_SP_OBJECTID}" \
        existingServicePrincipalClientId="${AKS_SP_APPID}" \
        existingServicePrincipalClientSecret="${AKS_SP_SECRET}" \
        AAD_TenantID="${AAD_INTEGRATED_TENANT}" \
        AAD_ServerAppID="${serverAppId}" \
        AAD_ServerAppSecret="${serverAppSecret}" \
        AAD_ClientAppID="${clientAppId}"
        
        
        