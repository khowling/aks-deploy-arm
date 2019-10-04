# exit on error
#set -e

while getopts "n:sa:t:" opt; do
  case ${opt} in
    a )
      ADDONS=$OPTARG
      if [[ $ADDONS =~ " appgw " ]]; then
        applicationGatewaySku="WAF_v2"
      fi

      if [[ $ADDONS =~ " afw " ]]; then
        azureFirewallEgress="true"
      fi

      if [[ $ADDONS =~ " aci " ]]; then
        azureContainerInsights="true"
      fi

      if [[ $ADDONS =~ " acr " ]]; then
        acrSku="Basic"
      fi
      ;;
    s )
      skip_app_creation="true"
      ;;
    t ) 
      orig_tenant=$(az account  show --query tenantId -o tsv)
      AAD_INTEGRATED_TENANT=$OPTARG
      ;;
    \? )
      echo "Unknown arg"
      show_usage=true
      
      ;; 
    esac
done

shift $((OPTIND -1))

if [ $# -ne 1 ] || [ "$show_usage" ]; then
    echo "Usage: $0 [-a <kured clusterautoscaler afw aci appgw acr>] [-n <kubenet|azure>] [-t tenentid] [-s] [<rg>/]<cluster_name>"
    echo "Optional args:"
    echo " -t: provide an alternative tenant id to secure your aks cluster users (you will need ADMIN rights on the tenant)"
    echo " -s: this will skip the recreation of the aad apps SPNs, (allowing re-running)"
    echo " -a: addons (appgw kured aci)"
    exit 1
fi

# check name
# https://docs.microsoft.com/en-us/azure/architecture/best-practices/naming-conventions#containers
#

CLUSTER_NAME=${1}
IFS='/' read -ra clust_array <<< "$CLUSTER_NAME"

if [ -z "${clust_array[1]}" ] ; then
    GROUP="${clust_array[0]}-rg"
    CLUSTER_NAME="${clust_array[0]}"
else
    GROUP="${clust_array[0]}"
    CLUSTER_NAME="${clust_array[1]}"
fi

# App Service name : 2-60, Alphanumeric or -, (but not begining or ending with -)
if [[ ! "$CLUSTER_NAME" =~ ^([[:alnum:]]|-)*$ ]] || [[ "$CLUSTER_NAME" =~ ^-|-$ ]] || [ ${#CLUSTER_NAME} -gt 63 ] || [ ${#CLUSTER_NAME} -lt 2 ] ; then
    echo 'AKS cluster name can only container alpha numeric charactors or "-" (but not begining or ending with "-"), and be between 2-63 long'
    exit 1
fi

echo "Creating Cluster [${CLUSTER_NAME}] in resource group [${GROUP}], with option [applicationGatewaySku=${applicationGatewaySku} azureFirewallEgress=${azureFirewallEgress} azureContainerInsights=${azureContainerInsights} acrSku=${acrSku}]..."

# Checking required tenant for the cluster federation
#
#
if [  "$orig_tenant" ]; then
    echo "You have selected an alternative tenent for cluster RBAC users, you will need to auth so we can create the required Apps, press ENTER to continue.."
    read
    
    az login --tenant $AAD_INTEGRATED_TENANT  --allow-no-subscriptions >/dev/null
else
    AAD_INTEGRATED_TENANT=$(az account show --query tenantId --output tsv)
fi

# Get the user details to create the kubernetes role assignment
USER_DETAILS=$(az ad signed-in-user show --query "[objectId,userPrincipalName]" -o tsv)

# Can require either the ObjectId or UPN depending on where the user is homed
USER_OBJECTID=$(echo $USER_DETAILS | cut -f 1 -d ' ')
USER_UPN=$(echo $USER_DETAILS | cut -f 2 -d ' ')

echo "This is the user we will add to the Kubernetes RBAC objectId: [$(az ad  signed-in-user show --query objectId -o tsv)]"


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

if [ -z "$serverAppId" ]; then
  echo "Error, failed to create AAD app, this is normally transiant, please try running the script again"
  if [ "$orig_tenant" ]; then
    echo "Changing back to defalt tenant [${orig_tenant}] to create Cluster"
    az login --tenant $orig_tenant >/dev/null
  fi
  exit 1
fi

echo "Created/Patched [${ADSERVER_APP}], appId: ${serverAppId}"
# Update the application group memebership claims
az ad app update --id $serverAppId --set groupMembershipClaims=All >/dev/null


if [ -z "$skip_app_creation" ] ; then
    # Now create a service principal for the server app (specific to granting permissions to resources in this tenant)
    # Create a service principal for the Azure AD application
    echo "Create a service principal for the app...."
    az ad sp create --id $serverAppId >/dev/null
fi

serverAppSecret=$(az ad sp credential reset --name $serverAppId --credential-description "AKSPassword" --query password -o tsv)

if [ -z "$skip_app_creation" ] ; then
    # Get the service principal secret
    echo "Adding directory permissions for Delegate & Applicaion to Directory.Read.All..."
    az ad app permission add \
        --id $serverAppId \
        --api 00000003-0000-0000-c000-000000000000 \
        --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 06da0dbc-49e2-44d2-8312-53f166ab848a=Scope 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role

    echo "Granting permissions..."
    az ad app permission grant --id $serverAppId --api 00000003-0000-0000-c000-000000000000 >/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Please check you have Global Admin rights on the directory, and run the script again"
        exit 1
    fi
    echo "Granting permissions ADMIN-consent..."
    az ad app permission admin-consent --id  $serverAppId >/dev/null
fi

#  Create the client application
#  Used when a user logon interactivlty to the AKS cluster with the Kubernetes CLI (kubectl)
echo "Creating Client app [${ADCLIENT_APP}]..."
clientAppId=$(az ad app create  --display-name $ADCLIENT_APP --native-app --reply-urls "https://${ADCLIENT_APP}" --query appId -o tsv)

if [ -z "$clientAppId" ]; then
  echo "Error, failed to create AAD app, this is normally transiant, please try running the script again"
  if [  "$orig_tenant" ]; then
    echo "Changing back to defalt tenant [${orig_tenant}] to create Cluster"
    az login --tenant $orig_tenant >/dev/null
  fi
  exit 1
fi

echo "Created/Patched ${ADCLIENT_APP}, AppId: ${clientAppId}"


if [ -z "$skip_app_creation" ] ; then
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
fi

if [ "$orig_tenant" ]; then
    echo "Changing back to defalt tenant [${orig_tenant}] to create Cluster"
    az login --tenant $orig_tenant >/dev/null
fi

# https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough-rm-template#create-a-service-principal

echo "Create Service Principle for AKS to manage Azure Resources [http://${CLUSTER_NAME}-sp]..."
AKS_SP=$(az ad sp create-for-rbac -n  "http://${CLUSTER_NAME}-sp" --skip-assignment  --query "[appId,password]" -o tsv)

# Can check this SPN can login using : az login --service-principal -u http://<>-sp --tenant <>

AKS_SP_APPID=$(echo $AKS_SP | cut -f 1 -d ' ')
AKS_SP_SECRET=$(echo $AKS_SP | cut -f 2 -d ' ')

if [ -z "$AKS_SP_APPID" ]; then
  echo "Error, failed to create AAD SPN, this is normally transiant, please try running the script again"
  exit 1
fi

echo "Created SPN appId: ${AKS_SP_APPID}"
AKS_SP_OBJECTID=$(az ad sp show --id $AKS_SP_APPID --query objectId -o tsv)

#  for ARM AKS format, see https://docs.microsoft.com/en-us/azure/templates/microsoft.containerservice/2019-02-01/managedclusters


echo "[DEBUG] Creating Cluster script: az group deployment create -g $GROUP \
--template-file ./azuredeploy.json \
--parameters \
resourceName=\"${CLUSTER_NAME}\" \
dnsPrefix=\"${CLUSTER_NAME}\" \
aksServicePrincipalObjectId=\"${AKS_SP_OBJECTID}\" \
aksServicePrincipalClientId=\"${AKS_SP_APPID}\" \
aksServicePrincipalClientSecret=\"${AKS_SP_SECRET}\" \
AAD_TenantID=\"${AAD_INTEGRATED_TENANT}\" \
AAD_ServerAppID=\"${serverAppId}\" \
AAD_ServerAppSecret=\"${serverAppSecret}\" \
AAD_ClientAppID=\"${clientAppId}\" \
applicationGatewaySku=\"${applicationGatewaySku}\" \
azureFirewallEgress=\"${azureFirewallEgress}\" \
azureContainerInsights=\"${azureContainerInsights}\" \
acrSku=\"${acrSku}\" \
"


az group create -l westeurope -n $GROUP >/dev/null

function setup_cluster {
    local cluster_api_url=$1
    local applicationGatewayName=$2
    local group=$3
    local cluster_name=$4
    local user_id=$5
    local msi_resourceid=$6
    local msi_clientid=$7

    local NAMESPACE="production"

    echo "Setting up namespace [${NAMESPACE}] with RBAC for signed in user"
    ## sign in with admin credentials
    az aks get-credentials -g $group -n $cluster_name --overwrite-existing --admin

    # Create a namespace
    kubectl create namespace $NAMESPACE

    # Crete the Role that defines the permissions on the namespace
    kubectl apply --namespace $NAMESPACE -f ./role-production-user-full-access.yaml

    # Create a RoleBinding
    kubectl create rolebinding creation-user-full-access --namespace $NAMESPACE --role=user-full-access --user=$user_id

    echo "Initialise tiller against new cluster"
    kubectl apply -f ./helm-rbac.yaml
    helm init --service-account tiller --node-selectors "beta.kubernetes.io/os"="linux"


    if [ "$applicationGatewayName" ]; then
        echo "Deploying the AppGW ingress controller"


        echo "Install the AAD POD Identity into the cluster ( Managed Identity Controller (MIC) deployment, the Node Managed Identity (NMI) daemon)..."
        kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml

        echo "Add the helm repo for Application Gateway Ingress Controller..."
        helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
        echo "Get the latest Chart..."
        helm repo update

        echo "Installing the Chart..."
        helm install application-gateway-kubernetes-ingress/ingress-azure \
            --name ingress-azure \
            --namespace default \
            --set appgw.name=$applicationGatewayName \
            --set appgw.resourceGroup=$group \
            --set appgw.subscriptionId=$(az account show --query id -o tsv) \
            --set appgw.shared=false \
            --set armAuth.type=aadPodIdentity \
            --set armAuth.identityResourceID=$msi_resourceid \
            --set armAuth.identityClientID=$msi_clientid \
            --set rbac.enabled=true \
            --set verbosityLevel=3 \
            --set kubernetes.watchNamespace=$NAMESPACE \
            --set aksClusterConfiguration.apiServerAddress=$cluster_api_url

    fi
}

echo "Sleeping for 3minutes before applying template to allow AAD propergation, please wait...."
sleep 3m
yn="y"

while true; do
    
    case $yn in
        [Yy]* ) 

            ARM_OUTPUT=$(az group deployment create -g $GROUP \
                --template-file ./azuredeploy.json \
                --parameters \
                    resourceName="${CLUSTER_NAME}" \
                    dnsPrefix="${CLUSTER_NAME}" \
                    aksServicePrincipalObjectId="${AKS_SP_OBJECTID}" \
                    aksServicePrincipalClientId="${AKS_SP_APPID}" \
                    aksServicePrincipalClientSecret="${AKS_SP_SECRET}" \
                    AAD_TenantID="${AAD_INTEGRATED_TENANT}" \
                    AAD_ServerAppID="${serverAppId}" \
                    AAD_ServerAppSecret="${serverAppSecret}" \
                    AAD_ClientAppID="${clientAppId}" \
                    applicationGatewaySku="${applicationGatewaySku}" \
                    azureFirewallEgress=${azureFirewallEgress} \
                    azureContainerInsights=${azureContainerInsights} \
                    acrSku="${acrSku}" \
                     --query "[properties.outputs.controlPlaneFQDN.value,properties.outputs.applicationGatewayName.value,properties.outputs.msiIdentityResourceId.value,properties.outputs.msiIdentityClientId.value]" --output tsv)

            if [ $? -eq 0 ] ; then
                out_array=($(echo $ARM_OUTPUT | tr " " "\n"))
                controlPlaneFQDN=${out_array[0]}
                applicationGatewayName=${out_array[1]}
                msiIdentityResourceId=${out_array[2]}
                msiIdentityClientId=${out_array[3]}

                echo "Success, got [controlPlaneFQDN=${controlPlaneFQDN}, applicationGatewayName=${applicationGatewayName}, msiIdentityResourceId=${msiIdentityResourceId}, msiIdentityClientId=${msiIdentityClientId} ]"
                echo "Setting up cluster...."


                setup_cluster "$controlPlaneFQDN" "$applicationGatewayName"  "$GROUP" "$CLUSTER_NAME" "$USER_OBJECTID" "$msiIdentityResourceId" "$msiIdentityClientId"
                exit 0
            else
                echo "Create cluster failed, if this may be because the sevice principle has not propergated yet.."
                read -p "Try template creation again [y/n]?" yn
            fi
            ;;
        [Nn]* ) 
            exit;;
        * ) 
            echo "Please answer yes or no.";;
    esac
done
        
