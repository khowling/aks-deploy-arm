
GROUP=${1:-"kh-aks-arm1"}
CLUSTER_NAME=${2:-"kh-aks-arm1"}
USER_ID=${3:-"ce27fa52-203f-47a8-854f-9587e3670195"}
NAMESPACE=example


echo "Setting up namespace [${NAMESPACE}] with RBAC for signed in user"
## sign in with admin credentials
az aks get-credentials -g $GROUP -n $CLUSTER_NAME --overwrite-existing --admin

# Create a namespace
kubectl create namespace $NAMESPACE

# Crete the Role that defines the permissions on the namespace
kubectl apply --namespace $NAMESPACE -f ./role-ns-user-full-access.yaml

# Create a RoleBinding
kubectl create rolebinding production-user-full-access --namespace $NAMESPACE --role=production-user-full-access --user=$USER_ID


