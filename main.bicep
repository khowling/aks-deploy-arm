param location string = resourceGroup().location
param resourceName string
param dnsPrefix string = '${resourceName}-dns'
param kubernetesVersion string = '1.19.3'
param enable_aad bool = false
param aad_tenant_id string = ''
param omsagent bool = false
param privateCluster bool = false
param custom_vnet bool = false
param osDiskType string = 'Epthemeral'
param agentVMSize string = 'Standard_DS2_v2'
param osDiskSizeGB int = 0
param agentCount int = 3
param agentCountMax int = 0
param maxPods int = 30
param networkPlugin string = 'azure'
param networkPolicy string = ''

param podCidr string = '10.244.0.0/16'
param serviceCidr string = '10.0.0.0/16'
param dnsServiceIP string = '10.0.0.10'
param dockerBridgeCidr string = '172.17.0.1/16'
//param serverFarmId string = resourceId('Microsoft.Web/sites', 'myWebsite')

var workspaceName = '${resourceName}-workspace'

//---------------------------------------------------------------------------------- User Identity
var user_identity = create_vnet
var user_identity_name = '${resourceName}uai'

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = if (user_identity) {
  name: user_identity_name
  location: location
}

//---------------------------------------------------------------------------------- ACR
param registries_sku string = ''
var acrName = '${replace(resourceName, '-', '')}acr'
resource acr 'Microsoft.ContainerRegistry/registries@2017-10-01' = if (!empty(registries_sku)) {
  name: acrName
  location: location
  sku: {
    name: registries_sku
  }
}

var AcrPullRole = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d'
resource aks_acr_pull 'Microsoft.ContainerRegistry/registries/providers/roleAssignments@2017-05-01' = if (!empty(registries_sku)) {
  name: '${acrName}/Microsoft.Authorization/${guid(resourceGroup().id)}identityacraccess'
  properties: {
    roleDefinitionId: AcrPullRole
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
  }
}

//---------------------------------------------------------------------------------- VNET
param vnetAddressPrefix string = '10.0.0.0/8'
param vnetAksSubnetAddressPrefix string = '10.240.0.0/16'
//param vnetInternalLBSubnetAddressPrefix string = '10.241.128.0/24'
param vnetAppGatewaySubnetAddressPrefix string = '10.2.0.0/16'
param vnetFirewallSubnetAddressPrefix string = '10.241.130.0/26'
var firewallIP = '10.241.130.4' // always .4

var create_vnet = custom_vnet || azureFirewalls

var vnetName = '${resourceName}-vnet'

//var internalLBSubnet = {
//  name: 'InternalLBSubnet'
//  properties: {
//    addressPrefix: vnetInternalLBSubnetAddressPrefix
//  }
//}
var appgw_subnet_name = '${appgw_name}-subnet'
var appgw_subnet = {
  name: appgw_subnet_name
  properties: {
    addressPrefix: vnetAppGatewaySubnetAddressPrefix
  }
}
var fw_subnet_name = 'AzureFirewallSubnet' // Required by FW
var fw_subnet = {
  name: fw_subnet_name
  properties: {
    addressPrefix: vnetFirewallSubnetAddressPrefix
  }
}

param azureFirewalls bool = false

var aks_subnet_name = 'aks-subnet'
var aks_subnet = azureFirewalls ? {
  name: aks_subnet_name
  properties: {
    addressPrefix: vnetAksSubnetAddressPrefix
    routeTable: {
      id: resourceId('Microsoft.Network/routeTables', routeFwTableName)
    }
  }
} : {
  name: aks_subnet_name
  properties: {
    addressPrefix: vnetAksSubnetAddressPrefix
  }
}

var subnets_1 = azureFirewalls ? concat(array(aks_subnet), array(fw_subnet)) : array(aks_subnet)
var final_subnets = ingressApplicationGateway ? concat(array(subnets_1), array(appgw_subnet)) : array(subnets_1)

resource vnet 'Microsoft.Network/virtualNetworks@2020-07-01' = if (create_vnet) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: final_subnets
  }
}

var networkContributorRole = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
resource aks_vnet_cont 'Microsoft.Network/virtualNetworks/subnets/providers/roleAssignments@2020-04-01-preview' = if (create_vnet) {
  name: '${vnet.name}/${aks_subnet_name}/Microsoft.Authorization/${guid(resourceGroup().id)}'
  properties: {
    roleDefinitionId: networkContributorRole
    principalId: uai.properties.principalId
    scope: '${vnet.id}/subnets/${aks_subnet_name}'
  }
}

//---------------------------------------------------------------------------------- Firewall
var routeFwTableName = '${resourceName}-route-fw'
resource vnet_udr 'Microsoft.Network/routeTables@2019-04-01' = if (azureFirewalls) {
  name: routeFwTableName
  location: location
  properties: {
    routes: [
      {
        name: 'AKSNodesEgress'
        properties: {
          addressPrefix: '0.0.0.0/1'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallIP
        }
      }
    ]
  }
}

var firewallPublicIpName = '${resourceName}-fw-ip'
resource fw_pip 'Microsoft.Network/publicIPAddresses@2018-08-01' = if (azureFirewalls) {
  name: firewallPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

var fw_name = '${resourceName}-fw'
resource fw 'Microsoft.Network/azureFirewalls@2019-04-01' = if (azureFirewalls) {
  name: fw_name
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${fw_subnet_name}'
          }
          publicIPAddress: {
            id: fw_pip.id
          }
        }
      }
    ]
    threatIntelMode: 'Alert'
    applicationRuleCollections: [
      {
        name: 'clusterRc1'
        properties: {
          priority: 101
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'MicrosoftServices'
              protocols: [
                {
                  port: 443
                  protocolType: 'Https'
                }
              ]
              targetFqdns: [
                '*.hcp.${location}.azmk8s.io'
                'mcr.microsoft.com'
                '*.data.mcr.microsoft.com'
                'management.azure.com'
                'login.microsoftonline.com'
                'packages.microsoft.com'
                'acs-mirror.azureedge.net'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
            }
            {
              name: 'UbuntuOS'
              protocols: [
                {
                  port: 80
                  protocolType: 'Http'
                }
              ]
              targetFqdns: [
                'security.ubuntu.com'
                'azure.archive.ubuntu.com'
                'changelogs.ubuntu.com'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
            }
            {
              name: 'NetworkTimeProtocol'
              protocols: [
                {
                  port: 123
                }
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
              targetFqdns: [
                'ntp.ubuntu.com'
              ]
            }
            {
              name: 'Monitor'
              protocols: [
                {
                  port: 443
                  protocolType: 'Https'
                }
              ]
              targetFqdns: [
                'dc.services.visualstudio.com'
                '*.ods.opinsights.azure.com'
                '*.oms.opinsights.azure.com'
                '*.monitoring.azure.com'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
            }
            {
              name: 'AzurePolicy'
              protocols: [
                {
                  port: 443
                  protocolType: 'Https'
                }
              ]
              targetFqdns: [
                'data.policy.core.windows.net'
                'store.policy.core.windows.net'
                'gov-prod-policy-data.trafficmanager.net'
                'raw.githubusercontent.com'
                'dc.services.visualstudio.com'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
            }
          ]
        }
      }
    ]
    networkRuleCollections: [
      {
        name: 'netRc1'
        properties: {
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'ControlPlaneTCP'
              protocols: [
                'TCP'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
              destinationAddresses: [
                'AzureCloud.${location}'
              ]
              destinationPorts: [
                '9000' /* For tunneled secure communication between the nodes and the control plane. */
                '22'
              ]
            }
            {
              name: 'ControlPlaneUDP'
              protocols: [
                'UDP'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
              destinationAddresses: [
                'AzureCloud.${location}'
              ]
              destinationPorts: [
                '1194' /* For tunneled secure communication between the nodes and the control plane. */
              ]
            }
            {
              name: 'AzureMonitorForContainers'
              protocols: [
                'TCP'
              ]
              sourceAddresses: [
                vnetAksSubnetAddressPrefix
              ]
              destinationAddresses: [
                'AzureMonitor'
              ]
              destinationPorts: [
                '443'
              ]
            }
          ]
        }
      }
    ]
  }
}

//---------------------------------------------------------------------------------- AKS
param ingressApplicationGateway bool = false

var appgw_name = '${resourceName}-appgw'

var aks_identity_user = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${uai.id}': {}
  }
}
var aks_identity_system = {
  type: 'SystemAssigned'
}

var autoScale = agentCountMax > agentCount
var agentPoolProfiles = {
  name: 'nodepool1'
  mode: 'System'
  osDiskType: osDiskType
  osDiskSizeGB: osDiskSizeGB
  count: agentCount
  vmSize: agentVMSize
  osType: 'Linux'
  vnetSubnetID: create_vnet ? '${vnet.id}/subnets/${aks_subnet_name}' : null
  maxPods: maxPods
  type: 'VirtualMachineScaleSets'
  enableAutoScaling: autoScale
}
var autoScaleProfile = {
  minCount: autoScale ? agentCount : null
  maxCount: autoScale ? agentCountMax : null
}

var addon_agic = {
  ingressApplicationGateway: {
    enabled: true
    config: {
      applicationGatewayName: appgw_name
      subnetCIDR: !create_vnet ? vnetAppGatewaySubnetAddressPrefix : null
      // 121011521000988: This doesn't work, bug : "code":"InvalidTemplateDeployment", IngressApplicationGateway addon cannot find subnet
      subnetID: create_vnet ? '${vnet.id}/subnets/${appgw_subnet_name}' : null
    }
  }
}
var addon_monitoring = {
  omsagent: {
    enabled: true
    config: {
      logAnalyticsWorkspaceResourceID: aks_law.id
    }
  }
}

param authorizedIPRanges string
param enablePrivateCluster bool = false

var aks_properties = {
  kubernetesVersion: kubernetesVersion
  enableRBAC: true
  dnsPrefix: dnsPrefix
  aadProfile: enable_aad ? {
    managed: true
    tenantID: aad_tenant_id
  } : null
  apiServerAccessProfile: !empty(authorizedIPRanges) ? {
    authorizedIPRanges: [
      authorizedIPRanges
    ]
  } : {
    enablePrivateCluster: enablePrivateCluster
  }
  agentPoolProfiles: autoScale ? array(union(agentPoolProfiles, autoScaleProfile)) : array(agentPoolProfiles)
  networkProfile: {
    loadBalancerSku: 'standard'
    networkPlugin: networkPlugin
    networkPolicy: networkPolicy
    podCidr: podCidr
    serviceCidr: serviceCidr
    dnsServiceIP: dnsServiceIP
    dockerBridgeCidr: dockerBridgeCidr
  }
}
//var aks_addonProfiles = ingressApplicationGateway && omsagent ? union(addon_monitoring, addon_agic) : omsagent ? addon_monitoring : ingressApplicationGateway ? addon_agic : null

resource aks 'Microsoft.ContainerService/managedClusters@2020-12-01' = {
  name: resourceName
  location: location
  properties: ingressApplicationGateway || omsagent ? union(aks_properties, {
    addonProfiles: ingressApplicationGateway && omsagent ? union(addon_monitoring, addon_agic) : omsagent ? addon_monitoring : addon_agic
  }) : aks_properties
  identity: user_identity ? aks_identity_user : aks_identity_system
}

var aks_law_name = '${resourceName}-workspace'
resource aks_law 'Microsoft.OperationalInsights/workspaces@2020-08-01' = if (omsagent) {
  name: aks_law_name
  location: location
}

/* output!
------ cluster
available properties are 
  provisioningState, 
  powerState, 
  kubernetesVersion, 
  dnsPrefix, 
  fqdn, 
  agentPoolProfiles, 
  windowsProfile, 
  servicePrincipalProfile.clientId 
  addonProfiles, 
  nodeResourceGroup, 
  enableRBAC, 
  networkProfile, 
  aadProfile, 
  maxAgentPools, 
  apiServerAccessProfile, 
  identityProfile.
  autoScalerProfile




"identity": {
  "principalId": "a4b92d4f-fc2c-4a3d-bdee-ad167a609955",
  "tenantId": "72f988bf-86f1-41af-91ab-2d7cd011db47",
  "type": "SystemAssigned",
  "userAssignedIdentities": null
},
------ kubelet
"identityProfile": {
  "kubeletidentity": {
    "clientId": "81b7b442-dc3a-4d69-a7fe-ca176c7bba70",
    "objectId": "aba6d50f-5f80-40e9-948c-cd3d86c87984",
    "resourceId": "/subscriptions/95efa97a-9b5d-4f74-9f75-a3396e23344d/resourcegroups/MC_myResourceGroup_myCluster_westeurope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/myCluster-agentpool"
  }

*/

// runtime -- properties of created resources

// we will automatically add the 'dependsOn' property.

// compipetime --- Instead of using the resourceId(), this will compile to [resourceId('Microsoft.Storage/storageAccounts', parameters('name'))]
//output blobid string = stg.id
//output blobid string = stg.name
//output blobid string = stg.apiVersion
//output blobid string = stg.type

// runtime -- properties of created resources - replacement for reference(...).*
//output blobEndpoint string = stg.properties.primaryEndpoints.blob

//output makeCapital string = toUpper('all lowercase')