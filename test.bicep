param location string = resourceGroup().location
param resourceName string = 'khkh02'
param ingressApplicationGateway bool = false

var appgw_subnet_name = 'appgw-sn'
var create_vnet = true

param vnetAddressPrefix string = '10.0.0.0/8'

var aks_subnet_name = 'aks-sn'

param vnetAksSubnetAddressPrefix string = '10.240.0.0/16'
param vnetAppGatewaySubnetAddressPrefix string = '10.2.0.0/16'

resource vnet 'Microsoft.Network/virtualNetworks@2020-07-01' = {
    name: 'khvnet1'
    location: location
    properties: {
        addressSpace: {
            addressPrefixes: [
                vnetAddressPrefix
            ]
        }
        subnets: [
            {
                name: aks_subnet_name
                properties: {
                    addressPrefix: vnetAksSubnetAddressPrefix
                    serviceEndpoints: []
                }
            }
            {
                name: appgw_subnet_name
                properties: {
                    addressPrefix: vnetAppGatewaySubnetAddressPrefix
                }
            }
        ]
    }
}

//---------------------------------------------------------------------------------- AppGateway - Only if Custom VNET, otherwise addon will auto-create

resource appgwpip 'Microsoft.Network/publicIPAddresses@2020-07-01' = if (create_vnet && ingressApplicationGateway) {
    name: '${resourceName}-appgwpip'
    location: location
    sku: {
        name: 'Standard'
    }
    properties: {
        publicIPAllocationMethod: 'Static'
    }
}
resource appgw 'Microsoft.Network/applicationGateways@2020-07-01' = if (create_vnet && ingressApplicationGateway) {
    name: '${resourceName}-appgw'
    location: location

    properties: {
        sku: {
            name: 'WAF_v2'
            tier: 'WAF_v2'
            capacity: 1
        }
        gatewayIPConfigurations: [
            {
                name: 'besubnet'
                properties: {
                    subnet: {
                        id: '${vnet.id}/subnets/${appgw_subnet_name}'
                    }
                }
            }
        ]
        frontendIPConfigurations: [
            {
                properties: {
                    publicIPAddress: {
                        id: '${appgwpip.id}'
                    }
                }
                name: 'appGatewayFrontendIP'
            }
        ]
        frontendPorts: [
            {
                name: 'appGatewayFrontendPort'
                properties: {
                    port: 80
                }
            }
        ]
        backendAddressPools: [
            {
                name: 'defaultaddresspool'
            }
        ]
        backendHttpSettingsCollection: [
            {
                name: 'defaulthttpsetting'
                properties: {
                    port: 80
                    protocol: 'Http'
                    cookieBasedAffinity: 'Disabled'
                    requestTimeout: 30
                    pickHostNameFromBackendAddress: true
                }
            }
        ]
        httpListeners: [
            {
                name: 'hlisten'
                properties: {
                    frontendIPConfiguration: {
                        id: concat(resourceId('Microsoft.Network/applicationGateways', '${resourceName}-appgw'), '/frontendIPConfigurations/appGatewayFrontendIP')
                    }
                    frontendPort: {
                        id: concat(resourceId('Microsoft.Network/applicationGateways', '${resourceName}-appgw'), '/frontendPorts/appGatewayFrontendPort')
                    }
                    protocol: 'Http'
                }
            }
        ]
        requestRoutingRules: [
            {
                name: 'appGwRoutingRuleName'
                properties: {
                    ruleType: 'Basic'
                    httpListener: {
                        id: concat(resourceId('Microsoft.Network/applicationGateways', '${resourceName}-appgw'), '/httpListeners/hlisten')
                    }
                    backendAddressPool: {
                        id: concat(resourceId('Microsoft.Network/applicationGateways', '${resourceName}-appgw'), '/backendAddressPools/defaultaddresspool')
                    }
                    backendHttpSettings: {
                        id: concat(resourceId('Microsoft.Network/applicationGateways', '${resourceName}-appgw'), '/backendHttpSettingsCollection/defaulthttpsetting')
                    }
                }
            }
        ]
    }
}

/*

output dns object = reference('/subscriptions/95efa97a-9b5d-4f74-9f75-a3396e23344d/resourceGroups/kh-common/providers/Microsoft.Network/dnszones/labhome.biz', '2018-05-01').properties

// bug

var propname = 'ptest'
var issue = true ? {
    prop1: {
        'ptest': {}
    }
} : {}

output out object = issue


var b1 = false
var b2 = true
var testout = b1 && b2 ? 'b12' : b1 ? 'b1' : b2 ? 'b2' : 'null'
var test2 = !empty([])


var aks_p = {
    kubernetesVersion: '1.19'
    enableRBAC: true
}

var aks_final = false ? union(aks_p, {
    newprop: true
}) : aks_p

var addons = {}

var addons1 = false ? union(addons, {
    myaddon1: {
        val: '1'
    }
}) : addons

var addons2 = true ? union(addons1, {
    myaddon2: {
        val: '2'
    }
}) : addons1

var aks_test = !empty(addons2) ? union(aks_final, {
    addonProfiles: addons2
}) : aks_final

output result object = aks_test

param currentTime string = utcNow()

resource dScript 'Microsoft.Resources/deploymentScripts@2019-10-01-preview' = {
    name: 'scriptWithStorage'
    location: 'westeurope'
    kind: 'AzureCLI'
    identity: {
        type: 'UserAssigned'
        userAssignedIdentities: {
            '${uamiId}': {}
        }
    }
    properties: {
        azCliVersion: '2.0.80'
        //storageAccountSettings: {
        //  storageAccountName: stg.name
        //  storageAccountKey: listKeys(stg.id, stg.apiVersion).keys[0].value
        //}
        scriptContent: 'ls -l '
        cleanupPreference: 'OnSuccess'
        retentionInterval: 'P1D'
        forceUpdateTag: currentTime // ensures script will run every time
    }
}
*/

// https://docs.microsoft.com/en-gb/azure/azure-arc/kubernetes/use-gitops-connected-cluster#using-azure-cli
// 2020-10-01-preview,2020-07-01-preview,2019-11-01-preview
/*
var location = 'westeurope'
resource gitops 'Microsoft.KubernetesConfiguration/sourceControlConfigurations@2019-11-01-preview' = {
    name: 'test'
    scope: reference(resourceId('Microsoft.ContainerService/managedClusters', 'kh-default'))
    //location: location
    properties: {
        operatorScope: 'cluster'
        enableHelmOperator: 'true'
        repositoryUrl: 'https://github.com/khowling/aks-deploy-arm'
    }
}
*/
