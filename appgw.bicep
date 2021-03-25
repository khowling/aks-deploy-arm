param resourceName string
param location string
param appgw_subnet_name string
param appgw_subnet_id string

//---------------------------------------------------------------------------------- AppGateway - Only if Custom VNET, otherwise addon will auto-create

resource appgwpip 'Microsoft.Network/publicIPAddresses@2020-07-01' = {
  name: '${resourceName}-appgwpip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}
resource appgw 'Microsoft.Network/applicationGateways@2020-07-01' = {
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
            id: appgw_subnet_id
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
