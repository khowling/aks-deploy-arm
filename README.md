
## Requirements

Install the latest version of the az-cli, detailed here: https://docs.microsoft.com/en-us/cli/azure/?view=azure-cli-latest

Install the latest version of the helm client, detailed here: https://helm.sh/docs/using_helm/#installing-the-helm-client

This template requires a number of preview features to be enavbled, including: 
* Standard LoadBalancer
* Zone support
* VMSS support

please follow these instructions before deploying this repo

https://docs.microsoft.com/en-us/azure/aks/availability-zones#register-feature-flags-for-your-subscription


This requires kubernetes version >=1.13.7, as we are using Zones and Standard load balancer, please ensure this version is avaiable in your region

```az aks get-versions --location <region> --output table```

NOTE: This script will enable AAD integration for AKS, you will need to ensure you have a _administartive login_ to your AAD tenant to grant the permissions needed by the AKS applications.  If you do not have administrator access to your subscriptions tenant, you can specify an anternative tenant (not related to your subscription tenant) using the -t flag.

Once the script has setup the requried AAD Applications and Service Principles, it will deploy the ARM Template ```azuredeploy.json```


## Run it

```
Usage: ./deploy.sh [-t tenentid] [-g resource_group_name] <cluster_name>
Optional args:
 -t: provide an alternative tenant id to secure your aks cluster users (you will need ADMIN rights on the tenant)
 -g: provide a resource group name, otherwise it will default to the cluster_name-rg
 -s: this will skip the recreation of the aad apps SPNs, (allowing re-running)
```

## ARM Template

The Template will create

(optional)
* `appgw-<cluster_name>` - This will be your `Application Gateway WAF` Ingress Service_ for your applications
* `appgwManagedIdentity<cluster_name>` - creates a `user-assigned Managed Identity` resource.  This Identity is used by the `application-gateway-ingress-controller` to configure routing rules. This identity is assigned the `Contributer` role on the Application Gateway & the `Reader` Role on the Application gateway Resource Group, in addition The `AKS Service Principle` will be assigned the `Managed Identity Operator` role to allow AKS to read the identity. This is all accomplished by the deplyoment `ClusterRoleAssignmentDeploymentForMSI`.

(optional)
* `acr<cluster_name>` - This is the `Azure Container Registry` to securly host your containers.  The `AKS Service Principle` will be assigned the `AcrPullRole` role on this resource to allow AKS to pull images (accomplished by the deplyoment `ClusterRoleAssignmentForKubenetesSPN`) 

(optional)
* `vnet-<cluster_name>` - This is a `VNET` to host the agent nodes.  The `AKS Service Principle` will be assigned the `Network Contributor` role on the agent subnet to allow AKS to create networking services (accomplished by the deplyoment `ClusterRoleAssignmentForKubenetesSPN`) 

(optional)
* `vnetfw-<cluster_name>` - This is a `Azure Firewall` to protect your cluster egress traffic.  A UDR (Routing Rule) is defined on the aks node subnet to ensure all cluster egress traffic is routed through the firewall. The firewall is configured with the folowing:
    * Application rules: Configure fully qualified domain names (FQDNs) that can be accessed from a subnet, this list is sourced from : https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic#required-ports-and-addresses-for-aks-clusters
    * Network rules: Configure rules that contain source addresses, protocols, destination ports, and destination addresses. This is blocked
    * NAT rules: Configure DNAT rules to allow incoming connections.  This is blocked
* `

(optional)
* `workspace-<cluster_name>` - This is the `Log Analytics Workspace` to store the cluster metrics and logging data 

* `<cluster_name>` - This is your AKS cluster resource.



# Post Script

The post creation script does a number of things

* Creates a new namespace called `example`, creates a new namespace Role `user-full-access`, and assigns the current user to that role in the `example` namespace.

Sets up POD Identity for the _Application Gateway Ingress Controller_
https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/docs/setup/install-existing.md#set-up-aad-pod-identity

* Install the Ingress Controller Helm Chart & update parameters.

https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/docs/setup/install-existing.md#install-ingress-controller-as-a-helm-chart


# Testing

expose a app in the example namespace


```
kubectl run nginx-app --image=nginx --port 80 --namespace example

kubectl expose deployment nginx-app  --namespace example

kubectl apply -f ingress-test.yaml   --namespace example
```

check progress: `k describe ingress --namespace example`




