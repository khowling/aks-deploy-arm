# exit on error
#set -e

createVNET=""
applicationGatewaySku=""
azureFirewallEgress=""
azureFirewallTCPAllow=""
azureContainerInsights=""
createOnPremGW=""
acrSku=""
networkPolicy=""
networkPlugin=""
skip_app_creation=""
AAD_INTEGRATED_TENANT=""
privateCluster=""
podSecurityPolicy=""
nginxIngress=""
dnsZoneRG=""
dnsZoneName=""
certEmail=""
agentCount="3"
agentCountMax=""
agentVMSize=""
osDiskSizeGB=""
kured="false"
installDemo=""


while getopts "do:v:c:l:n:sa:t:" opt; do
  case ${opt} in
    a )
      ADDONS=$OPTARG
      if [[ $ADDONS == "vnet" ]]; then
        createVNET="true"
      fi

      if [[ $ADDONS == "onprem" ]]; then
        createOnPremGW="true"
      fi

      if [[ $ADDONS == "appgw" ]]; then
        applicationGatewaySku="WAF_v2"
      fi

      if [[ $ADDONS =~ "afw=" ]]; then
        azureFirewallTCPAllow=($(echo $ADDONS | sed  -n 's/.*afw=\([^ ]*\).*/\1/p'))
        azureFirewallEgress="true"
      fi

      if [[ $ADDONS == "nginx" ]]; then
        nginxIngress="true"
      fi

      if [[ $ADDONS =~ "dns=" ]]; then
        dns_zone_info=($(echo $ADDONS | sed  -n 's/.*dns=\([^ ]*\).*/\1/p'))
        dns_args=($(echo "$dns_zone_info" | tr "/" "\n"))
        dnsZoneRG=${dns_args[0]}
        dnsZoneName=${dns_args[1]}

      fi

      if [[ $ADDONS =~ "cert=" ]]; then
        certEmail=($(echo $ADDONS | sed  -n 's/.*cert=\([[:alnum:]@\._-]*\).*/\1/p'))
      fi

      if [[ $ADDONS == "aci" ]]; then
        azureContainerInsights="true"
      fi

      if [[ $ADDONS == "kured" ]]; then
        kured="true"
      fi

      if [[ $ADDONS == "acr" ]]; then
        acrSku="Basic"
      fi
      if [[ $ADDONS == "calico" ]]; then
        networkPolicy="calico"
      fi
      if [[ $ADDONS == "private-api" ]]; then
        privateCluster="true"
      fi
      if [[ $ADDONS == "podsec" ]]; then
        podSecurityPolicy="true"
      fi
      if [[ $ADDONS =~ "clustrautoscaler=" ]]; then
        agentCountMax=($(echo $ADDONS | sed  -n 's/.*clustrautoscaler=\([0-9]*\).*/\1/p'))
      fi

      ;;
    c )
      agentCount=$OPTARG
      ;;
    d)
      installDemo="true"
      ;;
    l )
      location=$OPTARG
      ;;
    n )
      networkPlugin=$OPTARG
      ;;
    s )
      skip_app_creation="true"
      ;;
    t )
      if [[ "$OPTARG" = "current" ]]; then
        AAD_INTEGRATED_TENANT=$(az account show --query tenantId --output tsv)
      else
        AAD_INTEGRATED_TENANT=$OPTARG
        orig_tenant=$(az account  show --query tenantId -o tsv)
        orig_sub=$(az account  show --query id -o tsv)
      fi
      ;;
    v )
      agentVMSize=$OPTARG
      ;;
    o )
      osDiskSizeGB=$OPTARG
      ;;
    \? )
      echo "Unknown arg"
      show_usage=true

      ;;
    esac
done

## If
if [[ "$applicationGatewaySku" ||  "$azureFirewallEgress" || "$createOnPremGW" ]]; then
  createVNET="true"
fi

shift $((OPTIND -1))

if [ $# -ne 1 ] || [ -z "$location" ] || [ "$show_usage" ]; then
    echo "Usage: $0 ARGS [<rg>/]<cluster_name>"
    echo "args:"
    echo " <-l location> : Azure Region (required)"
    echo " [-c node count] : Mumber of virtual machine agent nodes in cluster (default 3)"
    echo " [-n kubenet | azure] : AKS network plugin (default: azure)"
    echo " [-v VM SKU ] : virtual machine size (default: Standard_D2s_v3)"
    echo " [-o OS-disksize ] : virtial machine OS disk size (defaults to VM default)"
    echo " [-t [tenantId]]: Use AAD Integration. If [tenantId] provided, an that alternative tenant id (YOU WILL NEED GLOBAL ADMIN role)"
    echo " [-a: features] : Can provide one or multiple features:"
    echo "     clustrautoscaler=<max> - Enable cluster AutoScaler with max nodes"
    echo "     vnet                   - Create custom vnet"
    echo "     onprem                 - Create vnet Gateway subnet"
    echo "     [nginx|appgw]          - Create ingress"
    echo "     dns=<rg/zone>          - Auto create dns records"
    echo "     cert=<cert_email>      - Auto create TLS Certs with lets encrypt"
    echo "     afw=<ServiceTag>       - Create Azure Firewall, include service tag for the region (ie AzureCloud.WestEurope)"
    echo "     podsec                 - Pod Security Policy"
    echo "     kured                  - Install kured"
    echo "     aci                    - Install Azure Container Insights"
    echo "     acr                    - Install Azure Container Registry"
    echo "     calico                 - Install calico"
    echo "     private-api            - Private Cluster (require jumpbox to access)"
    echo "     policy                 - Apply gatekeeper (future)"
    echo " [-d] : Install Demo App"
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

echo "Creating Cluster [${CLUSTER_NAME}] in resource group [${GROUP}], with Script Options
  certEmail=\"${certEmail}\"
  kured=\"${kured}\"
  nginxIngress=\"${nginxIngress}\"
  installDemo=\"${installDemo}\"
with ARM Options:
  createVNET=\"${createVNET}\"
  applicationGatewaySku=\"${applicationGatewaySku}\"
  azureFirewallEgress=\"${azureFirewallEgress}\"
  azureFirewallTCPAllow=\"${azureFirewallTCPAllow}\"
  createOnPremGW=\"${createOnPremGW}\"
  azureContainerInsights=\"${azureContainerInsights}\"
  acrSku=\"${acrSku}\"
  podSecurityPolicy=\"${podSecurityPolicy}\"
  networkPolicy=\"${networkPolicy}\"
  networkPlugin=\"${networkPlugin}\"
  dnsZoneRG=\"${dnsZoneRG}\"
  dnsZoneName=\"${dnsZoneName}\"
  agentCount=\"${agentCount}\"
  agentCountMax=\"${agentCountMax}\"
  agentVMSize=\"${agentVMSize}\"
  osDiskSizeGB=\"${osDiskSizeGB}\"
  privateCluster=\"${privateCluster}\"
]"

if [[ "$AAD_INTEGRATED_TENANT" ]]; then

  echo "Setting up AAD Integrated accounts....."
  # Checking required tenant for the cluster federation
  #
  #
  if [[  "$orig_tenant" ]]; then
      echo "You have selected an alternative tenent for cluster RBAC users, you will need to auth so we can create the required Apps, press ENTER to continue.."
      read

      az login --tenant $AAD_INTEGRATED_TENANT  --allow-no-subscriptions >/dev/null
      az account set -s $orig_sub > /dev/null
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
      az account set -s $orig_sub > /dev/null
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
          if [ "$orig_tenant" ]; then
            echo "Changing back to defalt tenant [${orig_tenant}] to create Cluster"
            az login --tenant $orig_tenant >/dev/null
            az account set -s $orig_sub > /dev/null
          fi
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
      az account set -s $orig_sub > /dev/null
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
      az account set -s $orig_sub > /dev/null
  fi
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

echo "Created SPN appId: ${AKS_SP_APPID}, getting objectID (sleep 5s)"
sleep 5s
AKS_SP_OBJECTID=$(az ad sp show --id $AKS_SP_APPID --query objectId -o tsv)

#  for ARM AKS format, see https://docs.microsoft.com/en-us/azure/templates/microsoft.containerservice/2019-02-01/managedclusters


echo "[DEBUG] Creating Cluster script: az group deployment create -g $GROUP \
--template-file ./azuredeploy.json \
--parameters \
resourceName="${CLUSTER_NAME}" \
dnsPrefix="${CLUSTER_NAME}-dns" \
${createVNET:+ createVNET="${createVNET}"} \
aksServicePrincipalObjectId="${AKS_SP_OBJECTID}" \
aksServicePrincipalClientId="${AKS_SP_APPID}" \
aksServicePrincipalClientSecret="${AKS_SP_SECRET}" \
${AAD_INTEGRATED_TENANT:+ AAD_TenantID="${AAD_INTEGRATED_TENANT}"} \
${serverAppId:+ AAD_ServerAppID="${serverAppId}"} \
${serverAppSecret:+ AAD_ServerAppSecret="${serverAppSecret}"} \
${clientAppId:+ AAD_ClientAppID="${clientAppId}"} \
${applicationGatewaySku:+ applicationGatewaySku="${applicationGatewaySku}"} \
${azureFirewallEgress:+ azureFirewallEgress="${azureFirewallEgress}"} \
${azureFirewallTCPAllow:+ azureFirewallTCPAllow="${azureFirewallTCPAllow}"} \
${createOnPremGW:+ createOnPremGW="${createOnPremGW}"} \
${azureContainerInsights:+ azureContainerInsights="${azureContainerInsights}"} \
${acrSku:+ acrSku="${acrSku}"} \
${podSecurityPolicy:+ podSecurityPolicy="${podSecurityPolicy}"} \
${networkPolicy:+ networkPolicy="${networkPolicy}"} \
${networkPlugin:+ networkPlugin="${networkPlugin}"} \
${dnsZoneRG:+ dnsZoneRG="${dnsZoneRG}"} \
${dnsZoneName:+ dnsZoneName="${dnsZoneName}"} \
agentCount="${agentCount}" \
${agentCountMax:+ agentCountMax="${agentCountMax}"} \
${agentVMSize:+ agentVMSize="${agentVMSize}"} \
${osDiskSizeGB:+ osDiskSizeGB="${osDiskSizeGB}"} \
${privateCluster:+ privateCluster="${privateCluster}" } \
"


az group create -l $location -n $GROUP >/dev/null

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

    if [[ "$kured" == "true" ]]; then
      echo "Installing kured DaemonSet...."
      kubectl apply -f https://github.com/weaveworks/kured/releases/download/1.2.0/kured-1.2.0-dockerhub.yaml
    fi

    echo "Waiting 30s for ready tiller pod...."
    sleep 30s

    # Depends on applicationGatewayName dns etc
    echo "Install the AAD POD Identity into the cluster ( Managed Identity Controller (MIC) deployment, the Node Managed Identity (NMI) daemon)..."
    kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml

    ingress_class=""
    if [ "$applicationGatewayName" != "-" ]; then
        echo "Deploying the AppGW ingress controller"
        ingress_class="azure/application-gateway"

        echo "Add the helm repo for Application Gateway Ingress Controller..."
        helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
        echo "Get the latest Chart..."
        helm repo update

        echo "Installing the Chart..."
        helm install application-gateway-kubernetes-ingress/ingress-azure \
            --name template-ingress-azure \
            --namespace default \
            --set image.tag=0.10.0-rc4 \
            --set appgw.name=$applicationGatewayName \
            --set appgw.resourceGroup=$group \
            --set appgw.subscriptionId=$(az account show --query id -o tsv) \
            --set appgw.shared=false \
            --set armAuth.type=aadPodIdentity \
            --set armAuth.identityResourceID=$msi_resourceid \
            --set armAuth.identityClientID=$msi_clientid \
            --set rbac.enabled=true \
            --set verbosityLevel=3 \
            --set aksClusterConfiguration.apiServerAddress=$cluster_api_url

#  --set kubernetes.watchNamespace=$NAMESPACE \
    fi

    if [ "$nginxIngress" ]; then
        echo "Deploying the NGINX ingress controller"
        ingress_class="nginx"
        helm install --name template-nginx-ingress --set controller.publishService.enabled=true  stable/nginx-ingress
    fi

    if [[ "$dnsZoneRG" ]]; then
      echo "Deploying Azure DNS Zone controller, (Zone in rg: ${dnsZoneRG})"
      # wget -qO - https://raw.githubusercontent.com/khowling/go-private-dns/master/deploy.yaml | sed -e 's/<<rg>>/'"$dnsZoneRG"'/' -e  's/<<subid>>/'"$(az account show --query id -o tsv)"'/' | kubectl apply -f -

      helm install  https://github.com/khowling/go-private-dns/blob/master/helm/azure-dns-controller-0.1.0.tgz?raw=true \
        --name template-dns-controller \
        --set controllerConfig.resourceGroup=$dnsZoneRG \
        --set controllerConfig.subscriptionId=$(az account show --query id -o tsv) \
        --set managedIdentity.identityClientId=$msi_clientid \
        --set managedIdentity.identityResourceId=$msi_resourceid

    fi

    if [[ "$certEmail" ]]; then
      echo "Deploying cert-manager"
      # Create the namespace for cert-managers
      kubectl create namespace cert-manager

      kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.11.0/cert-manager.yaml  --validate=false

      echo "Creating letsencrypt-prod ClusterIssuer with email ${certEmail} (sleeping 30s to allow webhook)"
      sleep 30s

      cat <<EOF | kubectl create -f -
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: "$certEmail"
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: $ingress_class
EOF

      if [[ "$ingress_class" ]] && [[ "$installDemo" ]]; then
        echo "Creating Certificate, waiting 3m to allow cert-manager to verify the domain (will create/delete a ingress)"
        sleep 3m

        demoapp_url="ecomm.${CLUSTER_NAME}.${dnsZoneName}"
        echo "Installing Demo eCommerce app ${demoapp_url}"

        helm install https://github.com/khowling/aks-ecomm-demo/blob/master/helm/aks-ecomm-demo-0.1.0.tgz?raw=true \
          --set name=ecommerce-demo \
          --set ingress.enabled=True,ingress.hosts[0].host="${demoapp_url}" \
          --set ingress.tls[0].secretName="tls-secret",ingress.tls[0].hosts[0]="${demoapp_url}" \
          --set ingress.annotations."kubernetes\.io/ingress\.class"="${ingress_class}" \
          --set ingress.annotations."cert-manager\.io/cluster-issuer"="letsencrypt-prod"  \
          --set ingress.enabled=True,ingress.hosts[0].paths[0]="/"
      fi
    fi
}


echo "Sleeping for 4minutes before applying template to allow AAD propergation, please wait...."
sleep 4m

yn="y"

while true; do

    case $yn in
        [Yy]* )

            ARM_OUTPUT=$(az group deployment create -g $GROUP \
                --template-file ./azuredeploy.json \
                --parameters \
                    resourceName="${CLUSTER_NAME}" \
                    dnsPrefix="${CLUSTER_NAME}-dns" \
                    ${createVNET:+ createVNET="${createVNET}"} \
                    aksServicePrincipalObjectId="${AKS_SP_OBJECTID}" \
                    aksServicePrincipalClientId="${AKS_SP_APPID}" \
                    aksServicePrincipalClientSecret="${AKS_SP_SECRET}" \
                    ${AAD_INTEGRATED_TENANT:+ AAD_TenantID="${AAD_INTEGRATED_TENANT}"} \
                    ${serverAppId:+ AAD_ServerAppID="${serverAppId}"} \
                    ${serverAppSecret:+ AAD_ServerAppSecret="${serverAppSecret}"} \
                    ${clientAppId:+ AAD_ClientAppID="${clientAppId}"} \
                    ${applicationGatewaySku:+ applicationGatewaySku="${applicationGatewaySku}"} \
                    ${azureFirewallEgress:+ azureFirewallEgress="${azureFirewallEgress}"} \
                    ${azureFirewallTCPAllow:+ azureFirewallTCPAllow="${azureFirewallTCPAllow}"} \
                    ${createOnPremGW:+ createOnPremGW="${createOnPremGW}"} \
                    ${azureContainerInsights:+ azureContainerInsights="${azureContainerInsights}"} \
                    ${acrSku:+ acrSku="${acrSku}"} \
                    ${podSecurityPolicy:+ podSecurityPolicy="${podSecurityPolicy}"} \
                    ${networkPolicy:+ networkPolicy="${networkPolicy}"} \
                    ${networkPlugin:+ networkPlugin="${networkPlugin}"} \
                    ${dnsZoneRG:+ dnsZoneRG="${dnsZoneRG}"} \
                    ${dnsZoneName:+ dnsZoneName="${dnsZoneName}"} \
                    agentCount="${agentCount}" \
                    ${agentCountMax:+ agentCountMax="${agentCountMax}"} \
                    ${agentVMSize:+ agentVMSize="${agentVMSize}"} \
                    ${osDiskSizeGB:+ osDiskSizeGB="${osDiskSizeGB}"} \
                    ${privateCluster:+ privateCluster="${privateCluster}" } \
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

