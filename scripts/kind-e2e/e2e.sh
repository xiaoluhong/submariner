#!/usr/bin/env bash
set -em

source $(git rev-parse --show-toplevel)/scripts/lib/debug_functions

### Variables ###

PRJ_ROOT=$(git rev-parse --show-toplevel)

### Functions ###

function print_logs() {
    logs=("$@")
    if [[ ${#logs[@]} -gt 0 ]]; then
        echo "(Watch the installation processes with \"tail -f ${logs[*]}\".)"
        for i in 1 2 3; do
            if [[ pids[$i] -gt -1 ]]; then
                wait ${pids[$i]}
                if [[ $? -ne 0 && $? -ne 127 ]]; then
                    echo Cluster $i creation failed:
                    cat ${logs[$i]}
                fi
                rm -f ${logs[$i]}
            fi
        done
    fi
}

function export_kubeconfig() {
    # TODO: Are both these mkdirs really necessary?
    mkdir -p ${PRJ_ROOT}/output/kind-config/dapper/
    mkdir -p ${PRJ_ROOT}/output/kind-config/local-dev/
    export KUBECONFIG=$(echo $kubecfgs_dir/kind-config-cluster{1..3} | sed 's/ /:/g')
}

function test_connection() {
    nginx_svc_ip_cluster3=$(kubectl --context=cluster3 get svc -l app=nginx-demo | awk 'FNR == 2 {print $3}')
    netshoot_pod=$(kubectl --context=cluster2 get pods -l app=netshoot | awk 'FNR == 2 {print $1}')

    echo "Testing connectivity between clusters - $netshoot_pod cluster2 --> $nginx_svc_ip_cluster3 nginx service cluster3"

    attempt_counter=0
    max_attempts=5
    until $(kubectl --context=cluster2 exec ${netshoot_pod} -- curl --output /dev/null -m 30 --silent --head --fail ${nginx_svc_ip_cluster3}); do
        if [[ ${attempt_counter} -eq ${max_attempts} ]];then
          echo "Max attempts reached, connection test failed!"
          exit 1
        fi
        attempt_counter=$(($attempt_counter+1))
    done
    echo "Connection test was successful!"
}

function enable_logging() {
    if kubectl --context=cluster1 rollout status deploy/kibana > /dev/null 2>&1; then
        echo Elasticsearch stack already installed, skipping...
    else
        echo Installing Elasticsearch...
        es_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cluster1-control-plane | head -n 1)
        kubectl --context=cluster1 apply -f ${PRJ_ROOT}/scripts/kind-e2e/logging/elasticsearch.yaml
        kubectl --context=cluster1 apply -f ${PRJ_ROOT}/scripts/kind-e2e/logging/filebeat.yaml
        echo Waiting for Elasticsearch to be ready...
        kubectl --context=cluster1 wait --for=condition=Ready pods -l app=elasticsearch --timeout=300s
        for i in 2 3; do
            kubectl --context=cluster${i} apply -f ${PRJ_ROOT}/scripts/kind-e2e/logging/filebeat.yaml
            kubectl --context=cluster${i} set env daemonset/filebeat -n kube-system ELASTICSEARCH_HOST=${es_ip} ELASTICSEARCH_PORT=30000
        done
    fi
}

function enable_kubefed() {
    KUBEFED_NS=kube-federation-system
    if kubectl --context=cluster1 rollout status deploy/kubefed-controller-manager -n ${KUBEFED_NS} > /dev/null 2>&1; then
        echo Kubefed already installed, skipping setup...
    else
        helm init --client-only
        helm repo add kubefed-charts https://raw.githubusercontent.com/kubernetes-sigs/kubefed/master/charts
        helm --kube-context cluster1 install kubefed-charts/kubefed --version=0.1.0-rc2 --name kubefed --namespace ${KUBEFED_NS} --set controllermanager.replicaCount=1
        for i in 1 2 3; do
            kubefedctl join cluster${i} --cluster-context cluster${i} --host-cluster-context cluster1 --v=2
            #master_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cluster${i}-control-plane | head -n 1)
            #kind_endpoint="https://${master_ip}:6443"
            #kubectl patch kubefedclusters -n ${KUBEFED_NS} cluster${i} --type merge --patch "{\"spec\":{\"apiEndpoint\":\"${kind_endpoint}\"}}"
        done
        #kubectl delete pod -l control-plane=controller-manager -n ${KUBEFED_NS}
        echo Waiting for kubefed control plain to be ready...
        kubectl --context=cluster1 wait --for=condition=Ready pods -l control-plane=controller-manager -n ${KUBEFED_NS} --timeout=120s
        kubectl --context=cluster1 wait --for=condition=Ready pods -l kubefed-admission-webhook=true -n ${KUBEFED_NS} --timeout=120s
    fi
}

function add_subm_gateway_label() {
    context=$1
    kubectl --context=$context label node $context-worker "submariner.io/gateway=true" --overwrite
}

function del_subm_gateway_label() {
    context=$1
    kubectl --context=$context label node $context-worker "submariner.io/gateway-" --overwrite
}

function deploy_netshoot() {
    context=$1
    worker_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $context-worker | head -n 1)
    echo Deploying netshoot on $context worker: ${worker_ip}
    kubectl --context=$context apply -f ${PRJ_ROOT}/scripts/kind-e2e/netshoot.yaml
    echo Waiting for netshoot pods to be Ready on $context.
    kubectl --context=$context rollout status deploy/netshoot --timeout=120s
}

function deploy_nginx() {
    context=$1
    worker_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $context-worker | head -n 1)
    echo Deploying nginx on $context worker: ${worker_ip}
    kubectl --context=$context apply -f ${PRJ_ROOT}/scripts/kind-e2e/nginx-demo.yaml
    echo Waiting for nginx-demo deployment to be Ready on $context.
    kubectl --context=$context rollout status deploy/nginx-demo --timeout=120s
}

function test_with_e2e_tests {
    set -o pipefail 

    cd ../test/e2e

    export_kubeconfig

    go test -v -args -ginkgo.v -ginkgo.randomizeAllSpecs \
        -submariner-namespace $subm_ns -dp-context cluster2 -dp-context cluster3 -dp-context cluster1 \
        -ginkgo.noColor -ginkgo.reportPassed \
        -ginkgo.reportFile ${DAPPER_SOURCE}/${DAPPER_OUTPUT}/e2e-junit.xml 2>&1 | \
        tee ${DAPPER_SOURCE}/${DAPPER_OUTPUT}/e2e-tests.log
}

function delete_subm_pods() {
    context=$1
    ns=$2
    if kubectl --context=$context wait --for=condition=Ready pods -l app=submariner-engine -n $ns --timeout=60s > /dev/null 2>&1; then
        echo Removing submariner engine pods...
        kubectl --context=$context delete pods -n submariner -l app=submariner-engine
    fi
    if kubectl --context=$context wait --for=condition=Ready pods -l app=submariner-routeagent -n $ns --timeout=60s > /dev/null 2>&1; then
        echo Removing submariner route agent pods...
        kubectl --context=$context delete pods -n submariner -l app=submariner-routeagent
    fi
}

function cleanup {
    destroy_kind_clusters

    if [[ $(docker ps -qf status=exited | wc -l) -gt 0 ]]; then
        echo Cleaning containers...
        docker ps -qf status=exited | xargs docker rm -f
    fi
    if [[ $(docker images -qf dangling=true | wc -l) -gt 0 ]]; then
        echo Cleaning images...
        docker images -qf dangling=true | xargs docker rmi -f
    fi
#    if [[ $(docker images -q --filter=reference='submariner*:local' | wc -l) -gt 0 ]]; then
#        docker images -q --filter=reference='submariner*:local' | xargs docker rmi -f
#    fi
    if [[ $(docker volume ls -qf dangling=true | wc -l) -gt 0 ]]; then
        echo Cleaning volumes...
        docker volume ls -qf dangling=true | xargs docker volume rm -f
    fi
}

### Main ###

status=$1
version=$2
logging=$3
kubefed=$4
deploy=$5
armada=$6

echo Starting with status: $status, k8s_version: $version, logging: $logging, kubefed: $kubefed, deploy: $deploy, armada: $armada

if [[ $armada = true ]]; then
    echo Will deploy k8s clusters using armada abstracting kind
    . kind-e2e/lib_armada_deploy_kind.sh
else
    echo Will deploy k8s clusters using kind
    . kind-e2e/lib_bash_deploy_kind.sh
fi

if [[ $status = clean ]]; then
    cleanup
    exit 0
elif [[ $status = onetime ]]; then
    echo Status $status: Will cleanup on EXIT signal
    trap cleanup EXIT
elif [[ $status != keep && $status != create ]]; then
    echo Unknown status: $status
    cleanup
    exit 1
fi

if [[ $deploy = operator ]]; then
    echo Will deploy submariner using the operator
    . kind-e2e/lib_operator_deploy_subm.sh
elif [ "$deploy" = helm ]; then
    echo Will deploy submariner using helm
    . kind-e2e/lib_helm_deploy_subm.sh
else
    echo Unknown deploy method: $deploy
    cleanup
    exit 1
fi

export_kubeconfig

create_kind_clusters $status $version $deploy

if [[ $logging = true ]]; then
    # TODO: Test this code path in CI
    enable_logging
fi

import_subm_images

if [[ $kubefed = true ]]; then
    # FIXME: Kubefed deploys are broken (not because of this commit)
    enable_kubefed
fi

# Install Helm/Operator deploy tool prerequisites
deploytool_prereqs

for i in 1 2 3; do
    context=cluster$i
    delete_subm_pods $context $subm_ns
    add_subm_gateway_label $context
done

setup_broker cluster1
install_subm_all_clusters

deploytool_postreqs

deploy_netshoot cluster2
deploy_nginx cluster3

test_connection

if [[ $status = keep || $status = onetime ]]; then
    test_with_e2e_tests
fi

if [[ $status = keep || $status = create ]]; then
    echo "your 3 virtual clusters are deployed and working properly with your local"
    echo "submariner source code, and can be accessed with:"
    echo ""
    echo "export KUBECONFIG=\$(echo \$(git rev-parse --show-toplevel)/$kubecfgs_rel_dir/kind-config-cluster{1..3} | sed 's/ /:/g')"
    echo ""
    echo "$ kubectl config use-context cluster1 # or cluster2, cluster3.."
    echo ""
    echo "to cleanup, just run: make e2e status=clean"
fi
