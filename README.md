
# AKS Deploy

A comprehensive, simplified AKS-based provisioning script that deploys a feature-complete, opinionated, best-practice AKS operating environment.

The script results in a taylored, operational AKS environment configured to meet your organsiational & applcations requirements, but incorporating the latest best-practise recommended configration and features.  

This accelerated provisioning script can save your project team many hours from sifting though the many advanced configration options and addons,  and manually hand-crafting environments. 

In addtion, the script has been designed so you can incorporated it into your CI/CD tools to fully automate future enviroenment creation

##  Conditional, taylored approach

The script configures all the recommended AKS options&addons, and includes all the additional resources to provide a fully-functional  environment ready to deploy production-ready applications.

One size does not fill all! To allow this script to be relevent for requirements between "I just want a managed PaaS to deploy a webapp" to "I need a hardened, locked down, secure environemtn to run my financial applications", the script conditionally provisions features/resources based on your operations requirements, and in many cases, offering preferences for Azure-native or OSS components covering:
* Cluster security and access
* Monitoring
* Application requirements (ingress)
* H/W requirements (IO optimised, CPU optimised etc)
* Hosting containers
* Required application features
* Networking commectivity requirements

## Running the Script

There a 2 ways to lauch the script
* The **highly** recommended way is to use this **[app](https://khcommon.z6.web.core.windows.net?v=v1.7)** to guide you through a series of questions where you can specify your operational needs, this outputs the command line you can then paste to launch the script
* Alternativly, you can manaully run the script, constructing your own command line options, this is a great option once you have been through the app once, and you want to add to your automated release process


    ```
    Usage: ./deploy.sh ARGS [<rg>/]<cluster_name>
    args:
    <-l location> : Azure Region (required)
    [-c node count] : Mumber of virtual machine agent nodes in cluster (default 3)
    [-n kubenet | azure] : AKS network plugin (default: azure)
    [-v VM SKU ] : virtual machine size (default: Standard_D2s_v3)
    [-o OS-disksize ] : virtial machine OS disk size (defaults to VM default)
    [-t [tenantId]]: Use AAD Integration. If [tenantId] provided, an that alternative tenant id (YOU WILL NEED GLOBAL ADMIN role)
    [-a: features] : Can provide one or multiple features:
        clustrautoscaler=<max> - Enable cluster AutoScaler with max nodes
        vnet                   - create custom vnet
        onprem                 - create vnet Gateway subnet
        [nginx|appgw]          - create ingress
        dns=<rg/zone>          - auto create dns records
        cert=<cert_email>      - auto create TLS Certs with lets encrypt
        afw                    - create Azure Firewall & setup
        podsec                 - Pod Security Policy
        kured                  - install kured
        aci                    - install Azure Container Insights
        acr                    - install Azure Container Registry
        calico                 - install calico
        private-api            - Private Cluster (require jumpbox to access)
        policy                 - Apply gatekeeper (future)
    [-d] : Install Demo App
    ```



## Requirements for running the script

Install the latest version of the az-cli, detailed here: https://docs.microsoft.com/en-us/cli/azure/?view=azure-cli-latest

Install the latest version of the helm client, detailed here: https://helm.sh/docs/using_helm/#installing-the-helm-client

NOTE: If the app indicates you will be using provisional features, ensure you follow these additional instructions:

https://docs.microsoft.com/en-us/azure/aks/availability-zones#register-feature-flags-for-your-subscription


This requires kubernetes version >=1.13.7, as we are using Zones and Standard load balancer, please ensure this version is avaiable in your region

```az aks get-versions --location <region> --output table```

NOTE: This script _can_ enable AAD integration for AKS, you will need to ensure you have a _administartive login_ to your AAD tenant to grant the permissions needed by the AKS applications.  If you do not have administrator access to your subscriptions tenant, you can specify an anternative tenant (not related to your subscription tenant) using the argument to the -t flag.

Once the script has setup the requried AAD Applications and Service Principles, it will deploy the ARM Template ```azuredeploy.json```



## ARM Template information

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






