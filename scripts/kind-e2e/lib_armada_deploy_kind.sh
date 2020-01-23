#!/bin/bash
# This should only be sourced
if [ "${0##*/}" = "lib_helm_deploy_subm.sh" ]; then
    echo "Don't run me, source me" >&2
    exit 1
fi

### Variables ###

# FIXME: Armada support for setting pod/service CIRDs via flags?
declare -A cluster_CIDRs=( ["cluster1"]="10.4.0.0/14" ["cluster2"]="10.8.0.0/14" ["cluster3"]="10.12.0.0/14" )
declare -A service_CIDRs=( ["cluster1"]="100.1.0.0/16" ["cluster2"]="100.2.0.0/16" ["cluster3"]="100.3.0.0/16" )

kubecfgs_rel_dir=scripts/output/kube-config/container/
kubecfgs_dir=${PRJ_ROOT}/$kubecfgs_rel_dir

### Functions ###

function install_armada() {
    # FIXME: Armada will be installed in dapper-base:latest after this patch, making this fn unnecessary.
    # FIXME: Remove this function after CI validates the rest of the patch
    test -x /usr/bin/armada && return
    # FIXME: Use a release from GitHub once one is available
    curl -L https://drive.google.com/u/0/uc\?id\=17r6E0RwbHcvlaFl0LKFICuAc_eGb13W9\&export\=download \
         -o /usr/bin/armada
    chmod a+x /usr/bin/armada
}

function create_kind_clusters() {
    deploy=$3

    # FIXME: Remove this function after CI validates the rest of the patch
    install_armada

    # FIXME: Somehow don't leak helm/operator-specific logic into this lib
    if [[ $deploy = operator ]]; then
        /usr/bin/armada create clusters -n 3 --weave
    elif [ "$deploy" = helm ]; then
        /usr/bin/armada create clusters -n 3 --weave --tiller
    fi
}

function import_subm_images() {
    docker tag quay.io/submariner/submariner:dev submariner:local
    docker tag quay.io/submariner/submariner-route-agent:dev submariner-route-agent:local

    /usr/bin/armada load docker-images --clusters cluster1,cluster2,cluster3 --images submariner:local,submariner-route-agent:local
}

function destroy_kind_clusters() {
    /usr/bin/armada destroy clusters
}
