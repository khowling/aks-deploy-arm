param resourceName string
param dnsPrefix string = '${resourceName}-dns'
param kubernetesVersion string = '1.19.3'
param enable_aad bool = false
param aad_tenant_id string = ''
param omsagent bool = false
param privateCluster bool = false
param createVNET bool = false
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

var location = resourceGroup().location
var workspaceName = '${resourceName}-workspace'
var autoScale = agentCountMax > agentCount

var user_identity = false
var user_identity_name = '${resourceName}uai'

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = if (user_identity) {
  name: user_identity_name
  location: location
}

param registries_sku string = ''
var acrName = '${replace(resourceName, '-', '')}acr'
resource acr 'Microsoft.ContainerRegistry/registries@2017-10-01' = if (!empty(registries_sku)) {
  name: acrName
  location: location
  sku: {
    name: registries_sku
  }
}

param vnetAddressPrefix string = '10.240.0.0/16'
param vnetAksSubnetAddressPrefix string = '10.240.0.0/17'
param vnetInternalLBSubnetAddressPrefix string = '10.240.128.0/24'
param vnetAppGatewaySubnetAddressPrefix string = '10.240.129.0/24'
param vnetFirewallSubnetAddressPrefix string = '10.240.130.0/26'

var vnetName = '${resourceName}-vnet'
var vnetAksSubnetName = 'AgentNodePoolsSubnet'
var default_subnets = [
  {
    name: vnetAksSubnetName
    properties: {
      addressPrefix: vnetAksSubnetAddressPrefix
    }
  }
  {
    name: 'InternalLBSubnet'
    properties: {
      addressPrefix: vnetInternalLBSubnetAddressPrefix
    }
  }
]
var vnetAppGatewaySubnet = {
  name: 'AppGwIngressSubnet'
  properties: {
    addressPrefix: vnetAppGatewaySubnetAddressPrefix
  }
}
var vnetFirewallSubnet = {
  name: 'AzureFirewallSubnet'
  properties: {
    addressPrefix: vnetFirewallSubnetAddressPrefix
  }
}

param applicationGateways_sku string = ''
param azureFirewalls bool = false
var default_plus_appgw_subnets = !empty(applicationGateways_sku) ? concat(array(default_subnets), array(vnetAppGatewaySubnet)) : array(default_subnets)
var default_plus_appgw_fw_subnets = azureFirewalls ? concat(array(default_plus_appgw_subnets), array(vnetFirewallSubnet)) : array(default_plus_appgw_subnets)
//var default_plus_appgw_fw_onprem_subnets = createOnPremGW? concat(array(default_plus_appgw_fw_subnets),array(vnetOnPremSubnet)): array(default_plus_appgw_fw_subnets)

resource vnet 'Microsoft.Network/virtualNetworks@2020-07-01' = if (createVNET) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: default_plus_appgw_fw_subnets
  }
}

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
          nextHopIpAddress: '10.240.130.4'
        }
      }
    ]
  }
}

var aks_identity_user = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${uai.id}': {}
  }
}
var aks_identity_system = {
  type: 'SystemAssigned'
}

var agentPoolProfiles = {
  name: 'nodepool1'
  mode: 'System'
  osDiskType: osDiskType
  osDiskSizeGB: osDiskSizeGB
  count: agentCount
  vmSize: agentVMSize
  osType: 'Linux'
  vnetSubnetID: createVNET ? resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'AgentNodePoolsSubnet') : null
  maxPods: maxPods
  type: 'VirtualMachineScaleSets'
  enableAutoScaling: autoScale
}
var autoScaleProfile = {
  minCount: autoScale ? agentCount : null
  maxCount: autoScale ? agentCountMax : null
}
var PoolProfiles = autoScale ? array(union(agentPoolProfiles, autoScaleProfile)) : array(agentPoolProfiles)

resource aks 'Microsoft.ContainerService/managedClusters@2020-12-01' = {
  name: resourceName
  location: location
  properties: {
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    dnsPrefix: dnsPrefix
    aadProfile: enable_aad ? {
      managed: true
      tenantID: aad_tenant_id
    } : null
    addonProfiles: omsagent ? {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: resourceId('Microsoft.OperationalInsights/workspaces', workspaceName)
        }
      }
    } : null
    apiServerAccessProfile: {
      enablePrivateCluster: privateCluster
    }
    agentPoolProfiles: PoolProfiles
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
  identity: user_identity ? aks_identity_user : aks_identity_system
}

// we will automatically add the 'dependsOn' property.

// compipetime --- Instead of using the resourceId(), this will compile to [resourceId('Microsoft.Storage/storageAccounts', parameters('name'))]
//output blobid string = stg.id
//output blobid string = stg.name
//output blobid string = stg.apiVersion
//output blobid string = stg.type

// runtime -- properties of created resources - replacement for reference(...).*
//output blobEndpoint string = stg.properties.primaryEndpoints.blob

//output makeCapital string = toUpper('all lowercase')